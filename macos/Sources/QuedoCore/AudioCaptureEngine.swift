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
    /// Audio engine start exceeded its safety timeout.
    case startTimedOut
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
        case .startTimedOut:
            return "start_timed_out"
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

private struct AudioEngineStartResult: @unchecked Sendable {
    let writer: AVAudioFile
    let outputURL: URL
}

/// Runs potentially blocking AVAudioEngine setup away from the actor.
///
/// Core Audio can block indefinitely while it is reconciling an input-device
/// route change. Keeping this work off the actor means cancellation, watchdogs,
/// and UI updates remain responsive even when that happens.
private final class AudioEngineStartOperation: @unchecked Sendable {
    enum Completion: @unchecked Sendable {
        case succeeded(AudioEngineStartResult)
        case failed(AudioCaptureError)
    }

    private let engine: AVAudioEngine
    private let outputURL: URL
    private let sessionID: UUID
    private let existingWriter: AVAudioFile?
    private let onFrame: @Sendable (UUID) -> Void
    private let onWriterFailure: @Sendable (UUID) -> Void
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var completion: Completion?
    private var cancelled = false

    init(
        engine: AVAudioEngine,
        outputURL: URL,
        sessionID: UUID,
        existingWriter: AVAudioFile? = nil,
        onFrame: @escaping @Sendable (UUID) -> Void,
        onWriterFailure: @escaping @Sendable (UUID) -> Void
    ) {
        self.engine = engine
        self.outputURL = outputURL
        self.sessionID = sessionID
        self.existingWriter = existingWriter
        self.onFrame = onFrame
        self.onWriterFailure = onWriterFailure
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }

            do {
                guard !isCancelled() else {
                    finish(.failed(.notRecording))
                    return
                }

                let input = engine.inputNode
                let format = input.inputFormat(forBus: 0)
                guard format.channelCount > 0 else {
                    finish(.failed(.noInputDevice))
                    return
                }

                let outputFile: AVAudioFile
                if let existingWriter {
                    outputFile = existingWriter
                } else {
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: Int(format.channelCount),
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                    outputFile = try AVAudioFile(forWriting: outputURL, settings: settings)
                }

                guard !isCancelled() else {
                    finish(.failed(.notRecording))
                    return
                }

                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [outputFile, sessionID, onFrame, onWriterFailure] buffer, _ in
                    do {
                        try outputFile.write(from: buffer)
                        onFrame(sessionID)
                    } catch {
                        onWriterFailure(sessionID)
                    }
                }

                guard !isCancelled() else {
                    input.removeTap(onBus: 0)
                    engine.stop()
                    finish(.failed(.notRecording))
                    return
                }

                engine.prepare()
                try engine.start()

                guard !isCancelled() else {
                    input.removeTap(onBus: 0)
                    engine.stop()
                    finish(.failed(.notRecording))
                    return
                }

                finish(.succeeded(AudioEngineStartResult(writer: outputFile, outputURL: outputURL)))
            } catch let error as AudioCaptureError {
                finish(.failed(error))
            } catch {
                finish(.failed(.streamOpenFailed))
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func wait(timeoutSeconds: TimeInterval) -> Completion? {
        guard group.wait(timeout: .now() + timeoutSeconds) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return completion
    }

    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func finish(_ completion: Completion) {
        lock.lock()
        if self.completion == nil {
            self.completion = completion
        }
        lock.unlock()
    }
}

/// Runs potentially blocking AVAudioEngine preparation away from the actor.
private final class AudioEnginePrepareOperation: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var prepared: Bool?

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            let inputFormat = engine.inputNode.inputFormat(forBus: 0)
            let canPrepare = inputFormat.channelCount > 0
            if canPrepare {
                engine.prepare()
            }
            lock.lock()
            prepared = canPrepare
            lock.unlock()
        }
    }

    func wait(timeoutSeconds: TimeInterval) -> Bool? {
        guard group.wait(timeout: .now() + timeoutSeconds) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }
}

/// Runs potentially blocking AVAudioEngine teardown away from the actor.
private final class AudioEngineTeardownOperation: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let reset: Bool
    private let group = DispatchGroup()

    init(engine: AVAudioEngine, reset: Bool) {
        self.engine = engine
        self.reset = reset
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if reset {
                engine.reset()
            }
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
    private var engineRunning = false
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
    private var activeStartOperation: AudioEngineStartOperation?
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
    public func prepareEngine() async {
        guard activeStartOperation == nil, sessionID == nil else {
            return
        }
        let operation = AudioEnginePrepareOperation(engine: engine)
        operation.start()
        let result = await Task.detached(priority: .utility) {
            operation.wait(timeoutSeconds: 1)
        }.value
        if result == nil {
            engine = AVAudioEngine()
            engineRunning = false
        }
    }

    /// Returns the latest audio-capture health without changing engine state.
    public func healthSnapshot() -> AudioCaptureHealthSnapshot {
        AudioCaptureHealthSnapshot(
            sessionID: sessionID,
            startedAt: startedAt,
            lastFrameAt: lastFrameAt,
            pendingErrorCode: pendingError?.diagnosticCode,
            engineRunning: engineRunning,
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
        engineRunning = false
        hasReceivedFrame = false
        recoveryAttempt = 0
        isRecovering = false
        recoveryReason = nil

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try await setupAndStart(sessionID: sessionID)
                startWatchdogs()
                return
            } catch {
                if let audioError = error as? AudioCaptureError, audioError == .notRecording {
                    throw audioError
                }
                lastError = error
                _ = await replaceEngineAfterTeardown(timeoutSeconds: 1)
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }

        if let audioError = lastError as? AudioCaptureError {
            if audioError == .noInputDevice || audioError == .startTimedOut {
                throw audioError
            }
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
            engineRunning = false
            engine = AVAudioEngine()
            throw pendingError
        }

        writer = nil
        outputURL = nil
        engineRunning = false
        engine = AVAudioEngine()
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
    public func cancelRecording() async {
        sessionID = nil
        activeStartOperation?.cancel()
        activeStartOperation = nil
        endWatchdogs()
        let oldEngine = engine
        engine = AVAudioEngine()
        engineRunning = false
        let teardown = AudioEngineTeardownOperation(engine: oldEngine, reset: true)
        teardown.start()
        _ = await Task.detached(priority: .userInitiated) {
            teardown.wait(timeoutSeconds: 1)
        }.value
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

    private func setupAndStart(sessionID: UUID, existingWriter: AVAudioFile? = nil) async throws {
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let outputURL = self.outputURL
            ?? workingDirectory.appendingPathComponent(sessionID.uuidString).appendingPathExtension("wav")
        if existingWriter == nil, fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let operation = AudioEngineStartOperation(
            engine: engine,
            outputURL: outputURL,
            sessionID: sessionID,
            existingWriter: existingWriter,
            onFrame: { [weak self] captureSessionID in
                Task {
                    await self?.markFrameReceived(for: captureSessionID)
                }
            },
            onWriterFailure: { [weak self] captureSessionID in
                Task {
                    await self?.markWriterFailure(for: captureSessionID)
                }
            }
        )
        activeStartOperation = operation
        operation.start()
        let completion = await Task.detached(priority: .userInitiated) {
            operation.wait(timeoutSeconds: 2)
        }.value
        if activeStartOperation === operation {
            activeStartOperation = nil
        }

        guard let completion else {
            operation.cancel()
            throw AudioCaptureError.startTimedOut
        }
        guard !operation.wasCancelled else {
            throw AudioCaptureError.notRecording
        }

        switch completion {
        case let .succeeded(result):
            writer = result.writer
            self.outputURL = result.outputURL
            engineRunning = true
        case let .failed(error):
            throw error
        }

        self.sessionID = sessionID
        self.startedAt = Date()
        self.lastFrameAt = nil
        self.hasReceivedFrame = false
        self.pendingError = nil
    }

    private func stopWithWatchdog(timeoutSeconds: TimeInterval) async -> Bool {
        let operation = AudioEngineTeardownOperation(engine: engine, reset: false)
        operation.start()
        return await Task.detached(priority: .userInitiated) {
            operation.wait(timeoutSeconds: timeoutSeconds)
        }.value
    }

    private func replaceEngineAfterTeardown(timeoutSeconds: TimeInterval) async -> Bool {
        let oldEngine = engine
        engine = AVAudioEngine()
        engineRunning = false
        let operation = AudioEngineTeardownOperation(engine: oldEngine, reset: true)
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

        if !engineRunning || Date().timeIntervalSince(lastFrameAt) > Self.callbackStallThreshold {
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
            engineRunning = false
            _ = await replaceEngineAfterTeardown(timeoutSeconds: 1)
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
                try await setupAndStart(sessionID: activeSessionID, existingWriter: existingWriter)
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
        _ = await replaceEngineAfterTeardown(timeoutSeconds: 1)
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

    private func replaceEngineAfterStopTimeout() {
        engine = AVAudioEngine()
        engineRunning = false
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

    private func handleSystemSleep() async {
        if sessionID != nil {
            pendingError = .streamOpenFailed
            _ = await replaceEngineAfterTeardown(timeoutSeconds: 1)
        }
    }

    private func handleSystemWake() async {
        await prepareEngine()
    }
}
