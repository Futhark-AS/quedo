import AVFoundation
import AppKit
import Foundation

/// Errors produced by capture operations.
public enum AudioCaptureError: Error, Sendable {
    /// Capture already active.
    case alreadyRecording
    /// Capture not active.
    case notRecording
    /// Unable to open capture stream.
    case streamOpenFailed
    /// No input device is available.
    case noInputDevice
    /// No frames were observed in watchdog window.
    case callbackStalled
    /// Stop operation timed out.
    case stopTimedOut
    /// Audio file writer failed.
    case writerFailed
}

public extension AudioCaptureError {
    /// Stable code used in diagnostics instead of relying on localized text.
    var diagnosticCode: String {
        switch self {
        case .alreadyRecording:
            return "already_recording"
        case .notRecording:
            return "not_recording"
        case .streamOpenFailed:
            return "stream_open_failed"
        case .noInputDevice:
            return "no_input_device"
        case .callbackStalled:
            return "callback_stalled"
        case .stopTimedOut:
            return "stop_timed_out"
        case .writerFailed:
            return "writer_failed"
        }
    }
}

/// Read-only health snapshot used by the application watchdog.
public struct AudioCaptureHealthSnapshot: Sendable {
    /// Session currently owned by the audio engine.
    public let sessionID: UUID?
    /// Start time of the active capture.
    public let startedAt: Date?
    /// Most recent callback frame time.
    public let lastFrameAt: Date?
    /// Stable pending error code, when the engine has detected a failure.
    public let pendingErrorCode: String?
    /// Whether the AVAudioEngine is currently running.
    public let engineRunning: Bool
    /// Whether an audio file writer is installed.
    public let writerReady: Bool
    /// Whether the engine is currently rebuilding after an audio interruption.
    public let isRecovering: Bool
    /// One-based recovery attempt, or zero when recovery is idle.
    public let recoveryAttempt: Int
    /// Trigger that caused the current recovery attempt.
    public let recoveryReason: String?

    /// Creates a health snapshot.
    public init(
        sessionID: UUID?,
        startedAt: Date?,
        lastFrameAt: Date?,
        pendingErrorCode: String?,
        engineRunning: Bool,
        writerReady: Bool,
        isRecovering: Bool = false,
        recoveryAttempt: Int = 0,
        recoveryReason: String? = nil
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.lastFrameAt = lastFrameAt
        self.pendingErrorCode = pendingErrorCode
        self.engineRunning = engineRunning
        self.writerReady = writerReady
        self.isRecovering = isRecovering
        self.recoveryAttempt = recoveryAttempt
        self.recoveryReason = recoveryReason
    }
}

/// Completed recording output.
public struct AudioCaptureResult: Sendable {
    /// Session identifier.
    public let sessionID: UUID
    /// Recorded file URL.
    public let fileURL: URL
    /// Duration in milliseconds.
    public let durationMS: Int

    /// Creates a recording result.
    public init(sessionID: UUID, fileURL: URL, durationMS: Int) {
        self.sessionID = sessionID
        self.fileURL = fileURL
        self.durationMS = durationMS
    }
}

/// Performs a potentially blocking AVAudioEngine stop away from the actor.
///
/// The engine instance is intentionally captured by this operation. If the
/// stop exceeds its budget, the owning actor can replace its engine safely
/// while this operation finishes against the old instance.
private final class AudioEngineStopOperation: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let group = DispatchGroup()

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    func wait(timeoutSeconds: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeoutSeconds) == .success
    }
}

/// AVAudioEngine-based capture service with bounded recovery policies.
public actor AudioCaptureEngine {
    private let fileManager: FileManager
    private let workingDirectory: URL
    private var engine: AVAudioEngine
    private var writer: AVAudioFile?
    private var outputURL: URL?
    private var sessionID: UUID?
    private var startedAt: Date?
    private var lastFrameAt: Date?
    private var hasReceivedFrame = false
    private var watchdogTask: Task<Void, Never>?
    private var armingWatchdogTask: Task<Void, Never>?
    private var pendingError: AudioCaptureError?
    private var isRecovering = false
    private var recoveryAttempt = 0
    private var recoveryReason: String?
    private var lastRecoverableCapture: AudioCaptureResult?
    private var observers: [NSObjectProtocol] = []
    private var observersInstalled = false

    private static let callbackStallThreshold: TimeInterval = 0.75
    private static let maxRecoveryAttempts = 3

    /// Creates capture engine.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.engine = AVAudioEngine()
        self.workingDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QuedoCapture", isDirectory: true)
    }

    /// Prepares the audio engine to reduce first-start latency.
    public func prepareEngine() {
        prepareEngineIfPossible()
    }

    /// Returns the latest audio-capture health without changing engine state.
    public func healthSnapshot() -> AudioCaptureHealthSnapshot {
        AudioCaptureHealthSnapshot(
            sessionID: sessionID,
            startedAt: startedAt,
            lastFrameAt: lastFrameAt,
            pendingErrorCode: pendingError?.diagnosticCode,
            engineRunning: engine.isRunning,
            writerReady: writer != nil,
            isRecovering: isRecovering,
            recoveryAttempt: recoveryAttempt,
            recoveryReason: recoveryReason
        )
    }

    /// Starts a recording session with retry and watchdog policies.
    public func startRecording(sessionID: UUID) async throws {
        ensureEnvironmentObserversInstalled()

        guard self.sessionID == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        lastRecoverableCapture = nil
        outputURL = nil
        hasReceivedFrame = false
        recoveryAttempt = 0
        isRecovering = false
        recoveryReason = nil

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try setupAndStart(sessionID: sessionID)
                startWatchdogs()
                return
            } catch {
                lastError = error
                teardownEngine(force: true)
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }

        if (lastError as? AudioCaptureError) == .noInputDevice {
            throw AudioCaptureError.noInputDevice
        }
        writer = nil
        outputURL = nil
        throw AudioCaptureError.streamOpenFailed
    }

    /// Waits until first audio frame is received for active session.
    public func waitForFirstFrame(timeout: Duration = .seconds(2)) async -> Bool {
        if lastFrameAt != nil {
            return true
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            guard sessionID != nil else {
                return false
            }
            if pendingError != nil {
                return false
            }
            if lastFrameAt != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        return lastFrameAt != nil
    }

    /// Stops recording and finalizes the audio artifact.
    public func stopRecording() async throws -> AudioCaptureResult {
        guard let activeSessionID = sessionID, let startedAt else {
            throw AudioCaptureError.notRecording
        }

        while isRecovering {
            try? await Task.sleep(for: .milliseconds(25))
            guard self.sessionID == activeSessionID else {
                throw AudioCaptureError.notRecording
            }
        }

        let stopSucceeded = await stopWithWatchdog(timeoutSeconds: 2)
        if !stopSucceeded {
            lastRecoverableCapture = makeRecoverableCapture()
            replaceEngineAfterStopTimeout()
            endWatchdogs()
            writer = nil
            outputURL = nil
            self.sessionID = nil
            self.startedAt = nil
            self.lastFrameAt = nil
            hasReceivedFrame = false
            isRecovering = false
            recoveryAttempt = 0
            recoveryReason = nil
            pendingError = nil
            throw AudioCaptureError.stopTimedOut
        }

        endWatchdogs()

        if let pendingError {
            lastRecoverableCapture = makeRecoverableCapture()
            self.pendingError = nil
            self.sessionID = nil
            self.startedAt = nil
            self.lastFrameAt = nil
            hasReceivedFrame = false
            writer = nil
            outputURL = nil
            isRecovering = false
            recoveryAttempt = 0
            recoveryReason = nil
            throw pendingError
        }

        writer = nil
        outputURL = nil
        self.sessionID = nil
        hasReceivedFrame = false
        isRecovering = false
        recoveryAttempt = 0
        recoveryReason = nil

        let durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        self.startedAt = nil
        let path = workingDirectory
            .appendingPathComponent(activeSessionID.uuidString)
            .appendingPathExtension("wav")
        return AudioCaptureResult(sessionID: activeSessionID, fileURL: path, durationMS: max(durationMS, 0))
    }

    /// Returns audio captured before a failed stop/recovery, once.
    public func takeRecoverableCapture() -> AudioCaptureResult? {
        defer { lastRecoverableCapture = nil }
        return lastRecoverableCapture
    }

    /// Cancels recording and tears down resources.
    public func cancelRecording() {
        sessionID = nil
        teardownEngine(force: true)
        endWatchdogs()
        startedAt = nil
        lastFrameAt = nil
        hasReceivedFrame = false
        writer = nil
        outputURL = nil
        pendingError = nil
        isRecovering = false
        recoveryAttempt = 0
        recoveryReason = nil
        lastRecoverableCapture = nil
    }

    private func ensureEnvironmentObserversInstalled() {
        guard !observersInstalled else {
            return
        }
        installEnvironmentObservers()
        observersInstalled = true
    }

    private func setupAndStart(sessionID: UUID) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)

        if format.channelCount == 0 {
            throw AudioCaptureError.noInputDevice
        }

        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let outputURL = workingDirectory.appendingPathComponent(sessionID.uuidString).appendingPathExtension("wav")
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: settings)
        writer = outputFile
        self.outputURL = outputURL

        try installInputTapAndStart(outputFile: outputFile, sessionID: sessionID)

        self.sessionID = sessionID
        self.startedAt = Date()
        self.lastFrameAt = nil
        self.hasReceivedFrame = false
        self.pendingError = nil
    }

    private func installInputTapAndStart(outputFile: AVAudioFile, sessionID: UUID) throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else {
                return
            }
            let captureSessionID = sessionID
            do {
                try outputFile.write(from: buffer)
                Task {
                    await self.markFrameReceived(for: captureSessionID)
                }
            } catch {
                Task {
                    await self.markWriterFailure(for: captureSessionID)
                }
            }
        }

        prepareEngineIfPossible()
        do {
            try engine.start()
        } catch {
            throw AudioCaptureError.streamOpenFailed
        }
    }

    private func stopWithWatchdog(timeoutSeconds: TimeInterval) async -> Bool {
        let operation = AudioEngineStopOperation(engine: engine)
        operation.start()
        return await Task.detached(priority: .userInitiated) {
            operation.wait(timeoutSeconds: timeoutSeconds)
        }.value
    }

    private func startWatchdogs() {
        armingWatchdogTask?.cancel()
        armingWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else {
                return
            }
            await self.handleArmingWatchdog()
        }

        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else {
                    return
                }
                await self.handleCallbackWatchdog()
            }
        }
    }

    private func endWatchdogs() {
        armingWatchdogTask?.cancel()
        armingWatchdogTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func handleArmingWatchdog() async {
        guard sessionID != nil, lastFrameAt == nil, !isRecovering else {
            return
        }

        await recoverAudioEngine(reason: "first_frame_timeout")
    }

    private func handleCallbackWatchdog() async {
        guard sessionID != nil, !isRecovering, pendingError == nil else {
            return
        }

        guard let lastFrameAt else {
            return
        }

        if !engine.isRunning || Date().timeIntervalSince(lastFrameAt) > Self.callbackStallThreshold {
            await recoverAudioEngine(reason: "callback_stalled")
        }
    }

    private func recoverAudioEngine(reason: String) async {
        guard let activeSessionID = sessionID, !isRecovering, pendingError == nil else {
            return
        }

        isRecovering = true
        recoveryReason = reason
        pendingError = nil
        var lastError: AudioCaptureError = .streamOpenFailed

        for attempt in 1...Self.maxRecoveryAttempts {
            guard sessionID == activeSessionID else {
                isRecovering = false
                recoveryAttempt = 0
                recoveryReason = nil
                return
            }

            recoveryAttempt = attempt
            lastFrameAt = nil
            teardownEngine(force: true)
            try? await Task.sleep(for: .milliseconds(attempt == 1 ? 100 : 250))

            guard sessionID == activeSessionID else {
                isRecovering = false
                recoveryAttempt = 0
                recoveryReason = nil
                return
            }

            do {
                guard let existingWriter = writer else {
                    throw AudioCaptureError.streamOpenFailed
                }
                try installInputTapAndStart(outputFile: existingWriter, sessionID: activeSessionID)
                if await waitForFirstFrame(timeout: .seconds(1)) {
                    isRecovering = false
                    recoveryAttempt = 0
                    recoveryReason = nil
                    pendingError = nil
                    return
                }
                lastError = pendingError ?? .callbackStalled
            } catch let error as AudioCaptureError {
                lastError = error
            } catch {
                lastError = .streamOpenFailed
            }
        }

        isRecovering = false
        recoveryAttempt = 0
        recoveryReason = nil
        pendingError = switch lastError {
        case .noInputDevice:
            .noInputDevice
        case .writerFailed:
            .writerFailed
        default:
            .callbackStalled
        }
        teardownEngine(force: true)
        lastRecoverableCapture = makeRecoverableCapture()
    }

    private func markFrameReceived(for sessionID: UUID) {
        guard self.sessionID == sessionID else {
            return
        }
        lastFrameAt = Date()
        hasReceivedFrame = true
    }

    private func markWriterFailure(for sessionID: UUID) {
        guard self.sessionID == sessionID else {
            return
        }
        pendingError = .writerFailed
    }

    private func makeRecoverableCapture() -> AudioCaptureResult? {
        guard
            let sessionID,
            let startedAt,
            let outputURL,
            hasReceivedFrame,
            fileManager.fileExists(atPath: outputURL.path),
            let attributes = try? fileManager.attributesOfItem(atPath: outputURL.path),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.int64Value > 44
        else {
            return nil
        }

        return AudioCaptureResult(
            sessionID: sessionID,
            fileURL: outputURL,
            durationMS: max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
        )
    }

    private func teardownEngine(force: Bool) {
        if force {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
            engine = AVAudioEngine()
        } else {
            engine.stop()
        }
    }

    private func replaceEngineAfterStopTimeout() {
        engine = AVAudioEngine()
    }

    private func installEnvironmentObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let configObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in
            Task {
                await self?.handleRouteChange()
            }
        }
        observers.append(configObserver)

        let willSleep = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task {
                await self?.handleSystemSleep()
            }
        }
        observers.append(willSleep)

        let didWake = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task {
                await self?.handleSystemWake()
            }
        }
        observers.append(didWake)
    }

    private func handleRouteChange() async {
        guard sessionID != nil else {
            return
        }
        await recoverAudioEngine(reason: "route_changed")
    }

    private func handleSystemSleep() {
        if sessionID != nil {
            pendingError = .streamOpenFailed
            teardownEngine(force: true)
        }
    }

    private func handleSystemWake() {
        prepareEngineIfPossible()
    }

    private func prepareEngineIfPossible() {
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            return
        }
        engine.prepare()
    }
}
