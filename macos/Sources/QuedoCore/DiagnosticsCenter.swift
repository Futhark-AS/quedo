import Foundation

/// Diagnostic event payload.
public struct DiagnosticEvent: Sendable {
    /// Event name.
    public let name: String
    /// Optional session identifier.
    public let sessionID: UUID?
    /// Optional operation identifier for work that is not a recording session.
    public let operationID: UUID?
    /// Event attributes.
    public let attributes: [String: String]
    /// Event timestamp.
    public let timestamp: Date
    /// Severity written to both the structured file log and OSLog.
    public let level: LogLevel

    /// Creates a diagnostic event.
    public init(
        name: String,
        sessionID: UUID?,
        attributes: [String: String],
        timestamp: Date = Date(),
        operationID: UUID? = nil,
        level: LogLevel = .info
    ) {
        self.name = name
        self.sessionID = sessionID
        self.operationID = operationID
        self.attributes = attributes
        self.timestamp = timestamp
        self.level = level
    }
}

/// Metric value type for telemetry.
public struct MetricPoint: Sendable {
    /// Metric name.
    public let name: String
    /// Numeric value.
    public let value: Double
    /// Dimensions.
    public let tags: [String: String]
    /// Timestamp.
    public let timestamp: Date
    /// Optional session identifier for request-level correlation.
    public let sessionID: UUID?
    /// Optional operation identifier for request-level correlation.
    public let operationID: UUID?

    /// Creates a metric point.
    public init(
        name: String,
        value: Double,
        tags: [String: String],
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        operationID: UUID? = nil
    ) {
        self.name = name
        self.value = value
        self.tags = tags
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.operationID = operationID
    }
}

/// Last durable runtime state written by the diagnostics subsystem.
///
/// This file intentionally contains no transcript text, audio, API keys, or
/// other user content. It exists so a later launch can explain where a prior
/// process stopped even when the process never reached its normal error path.
public struct RuntimeDiagnosticsSnapshot: Codable, Sendable {
    /// Snapshot format version.
    public let schemaVersion: Int
    /// Process identifier that last wrote the snapshot.
    public let processID: Int32
    /// Snapshot write time.
    public let updatedAt: Date
    /// `idle`, `active`, `stalled`, `success`, `failed`, or `cancelled`.
    public let status: String
    /// Active or most recently active session.
    public let sessionID: UUID?
    /// Active or most recent operation.
    public let operationID: UUID?
    /// Lifecycle phase at the last update.
    public let phase: String
    /// Fine-grained stage at the last update.
    public let stage: String
    /// Start time of the active session, when available.
    public let sessionStartedAt: Date?
    /// Last known forward progress time.
    public let lastProgressAt: Date?
    /// Bounded, non-sensitive context for the last stage.
    public let details: [String: String]

    /// Creates a runtime snapshot.
    public init(
        schemaVersion: Int = 1,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        updatedAt: Date = Date(),
        status: String,
        sessionID: UUID?,
        operationID: UUID?,
        phase: String,
        stage: String,
        sessionStartedAt: Date?,
        lastProgressAt: Date?,
        details: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.processID = processID
        self.updatedAt = updatedAt
        self.status = status
        self.sessionID = sessionID
        self.operationID = operationID
        self.phase = phase
        self.stage = stage
        self.sessionStartedAt = sessionStartedAt
        self.lastProgressAt = lastProgressAt
        self.details = details
    }
}

/// Subsystems tracked by global recovery budget.
public enum RecoverySubsystem: String, Sendable {
    /// Audio capture subsystem.
    case audio
    /// Hotkey subsystem.
    case hotkey
    /// Provider subsystem.
    case provider
    /// Output subsystem.
    case output
}

/// Central diagnostics and telemetry manager.
public actor DiagnosticsCenter {
    private let historyStore: HistoryStore
    private let logger: AppLogger
    private let uploadEndpoint: URL?

    private var recoveryAttempts: [RecoverySubsystem: [Date]] = [:]
    private var counterRollup: [String: Double] = [:]
    private var rollupTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?

    private var runtimeStatus = "idle"
    private var runtimeSessionID: UUID?
    private var runtimeOperationID: UUID?
    private var runtimePhase = "booting"
    private var runtimeStage = "startup"
    private var runtimeSessionStartedAt: Date?
    private var runtimeLastProgressAt: Date?
    private var runtimeDetails: [String: String] = [:]
    private var runtimeLastEvent: String?
    private var initialized = false

    /// Creates diagnostics center.
    public init(historyStore: HistoryStore, logger: AppLogger, uploadEndpoint: URL? = nil) {
        self.historyStore = historyStore
        self.logger = logger
        self.uploadEndpoint = uploadEndpoint
    }

    /// Loads the previous runtime marker and starts periodic rollups.
    ///
    /// Startup calls this before accepting user actions so a prior interrupted
    /// session cannot race a newly-created trace.
    public func initialize() async {
        guard !initialized else {
            return
        }
        initialized = true
        await inspectPreviousRuntime()
        startRollupLoop()
    }

    /// Emits a structured event entry.
    public func emit(_ event: DiagnosticEvent) async {
        var payload = event.attributes
        payload["timestamp"] = ISO8601DateFormatter().string(from: event.timestamp)
        payload["level"] = event.level.rawValue
        if let sessionID = event.sessionID {
            payload["session_id"] = sessionID.uuidString
        }
        if let operationID = event.operationID {
            payload["operation_id"] = operationID.uuidString
        }

        do {
            try await historyStore.appendEvent(
                sessionID: event.sessionID,
                eventName: event.name,
                payload: payload,
                createdAt: event.timestamp
            )
        } catch {
            await logger.log(
                .error,
                "Failed to append diagnostic event",
                metadata: ["event": event.name].merging(diagnosticPersistenceAttributes(for: error)) { current, _ in current }
            )
        }

        runtimeLastEvent = event.name
        await logger.log(event.level, event.name, metadata: payload)
    }

    /// Records a metric point and updates in-memory rollup.
    public func recordMetric(_ point: MetricPoint) async {
        let key = metricKey(name: point.name, tags: point.tags)
        counterRollup[key, default: 0] += point.value

        await emit(
            DiagnosticEvent(
                name: "metric_\(point.name)",
                sessionID: point.sessionID,
                attributes: point.tags.merging([
                    "value": String(point.value),
                    "timestamp": ISO8601DateFormatter().string(from: point.timestamp)
                ]) { current, _ in current },
                timestamp: point.timestamp,
                operationID: point.operationID,
                level: .debug
            )
        )
    }

    /// Starts a durable trace for one end-to-end recording operation.
    public func beginSessionTrace(
        sessionID: UUID,
        operationID: UUID? = nil,
        phase: String,
        stage: String,
        details: [String: String] = [:],
        providerPrimary: ProviderKind = .groq,
        language: String = "auto",
        outputMode: OutputMode = .none
    ) async {
        do {
            try await historyStore.ensureDiagnosticSession(
                sessionID: sessionID,
                providerPrimary: providerPrimary,
                language: language,
                outputMode: outputMode
            )
        } catch {
            await logger.log(
                .error,
                "Failed to create diagnostic session marker",
                metadata: diagnosticPersistenceAttributes(for: error).merging([
                    "session_id": sessionID.uuidString
                ]) { current, _ in current }
            )
        }

        let now = Date()
        runtimeStatus = "active"
        runtimeSessionID = sessionID
        runtimeOperationID = operationID ?? sessionID
        runtimePhase = phase
        runtimeStage = stage
        runtimeSessionStartedAt = now
        runtimeLastProgressAt = now
        runtimeDetails = details
        await writeRuntimeSnapshot()

        await emit(
            DiagnosticEvent(
                name: "session_trace_started",
                sessionID: sessionID,
                attributes: details.merging([
                    "phase": phase,
                    "stage": stage
                ]) { current, _ in current },
                operationID: operationID
            )
        )
        await writeRuntimeSnapshot()
    }

    /// Updates the durable last-known progress marker without adding a noisy
    /// database row for every audio callback.
    public func markSessionProgress(
        sessionID: UUID,
        operationID: UUID? = nil,
        phase: String,
        stage: String,
        details: [String: String] = [:]
    ) async {
        guard acceptsActiveSessionTrace(sessionID: sessionID, operationID: operationID) else {
            return
        }

        runtimeStatus = "active"
        runtimeSessionID = sessionID
        runtimeOperationID = operationID ?? runtimeOperationID ?? sessionID
        runtimePhase = phase
        runtimeStage = stage
        runtimeLastProgressAt = Date()
        runtimeDetails = details
        await writeRuntimeSnapshot()
    }

    /// Returns the in-memory runtime snapshot used by the watchdog.
    public func runtimeSnapshot() -> RuntimeDiagnosticsSnapshot {
        makeRuntimeSnapshot()
    }

    /// Records a stall with the last known phase, stage, and age.
    public func recordSessionStall(
        sessionID: UUID,
        operationID: UUID? = nil,
        phase: String,
        stage: String,
        ageSeconds: Double,
        details: [String: String] = [:]
    ) async {
        guard acceptsActiveSessionTrace(sessionID: sessionID, operationID: operationID) else {
            return
        }

        let effectiveOperationID = operationID ?? runtimeOperationID
        runtimeStatus = "stalled"
        runtimeSessionID = sessionID
        runtimeOperationID = effectiveOperationID ?? sessionID
        runtimePhase = phase
        runtimeStage = stage
        runtimeDetails = details.merging([
            "age_ms": String(Int(ageSeconds * 1000))
        ]) { current, _ in current }
        await writeRuntimeSnapshot()

        await emit(
            DiagnosticEvent(
                name: "session_stall_detected",
                sessionID: sessionID,
                attributes: runtimeDetails.merging([
                    "phase": phase,
                    "stage": stage,
                    "age_ms": String(Int(ageSeconds * 1000))
                ]) { current, _ in current },
                operationID: effectiveOperationID,
                level: .error
            )
        )
        await writeRuntimeSnapshot()
    }

    /// Completes the durable trace while retaining the last session details.
    public func endSessionTrace(
        sessionID: UUID,
        operationID: UUID? = nil,
        outcome: String,
        phase: String,
        stage: String,
        details: [String: String] = [:]
    ) async {
        guard acceptsActiveSessionTrace(sessionID: sessionID, operationID: operationID) else {
            return
        }

        let effectiveOperationID = operationID ?? runtimeOperationID
        runtimeStatus = outcome
        runtimeSessionID = sessionID
        runtimeOperationID = effectiveOperationID ?? sessionID
        runtimePhase = phase
        runtimeStage = stage
        runtimeLastProgressAt = Date()
        runtimeDetails = details
        await writeRuntimeSnapshot()

        await emit(
            DiagnosticEvent(
                name: "session_trace_ended",
                sessionID: sessionID,
                attributes: details.merging([
                    "outcome": outcome,
                    "phase": phase,
                    "stage": stage
                ]) { current, _ in current },
                operationID: effectiveOperationID,
                level: outcome == "success" || outcome == "cancelled" ? .info : .error
            )
        )
        await writeRuntimeSnapshot()
    }

    /// Starts a durable application-level trace for boot and initialization.
    public func beginApplicationTrace(
        operationID: UUID,
        stage: String,
        details: [String: String] = [:]
    ) async {
        let now = Date()
        runtimeStatus = "active"
        runtimeSessionID = nil
        runtimeOperationID = operationID
        runtimePhase = "booting"
        runtimeStage = stage
        runtimeSessionStartedAt = now
        runtimeLastProgressAt = now
        runtimeDetails = details
        await writeRuntimeSnapshot()

        await emit(
            DiagnosticEvent(
                name: "application_trace_started",
                sessionID: nil,
                attributes: details.merging(["stage": stage]) { current, _ in current },
                operationID: operationID
            )
        )
        await writeRuntimeSnapshot()
    }

    /// Advances an application-level boot trace.
    public func markApplicationProgress(
        operationID: UUID,
        stage: String,
        details: [String: String] = [:]
    ) async {
        guard runtimeSessionID == nil,
              runtimeStatus == "active" || runtimeStatus == "stalled",
              runtimeOperationID == operationID
        else {
            return
        }

        runtimeStatus = "active"
        runtimePhase = "booting"
        runtimeStage = stage
        runtimeLastProgressAt = Date()
        runtimeDetails = details
        await writeRuntimeSnapshot()
    }

    /// Completes an application-level boot trace.
    public func endApplicationTrace(
        operationID: UUID,
        outcome: String,
        phase: String,
        stage: String,
        details: [String: String] = [:]
    ) async {
        guard runtimeSessionID == nil, runtimeOperationID == operationID else {
            return
        }

        runtimeStatus = outcome
        runtimePhase = phase
        runtimeStage = stage
        runtimeLastProgressAt = Date()
        runtimeDetails = details
        await writeRuntimeSnapshot()

        await emit(
            DiagnosticEvent(
                name: "application_trace_ended",
                sessionID: nil,
                attributes: details.merging([
                    "outcome": outcome,
                    "phase": phase,
                    "stage": stage
                ]) { current, _ in current },
                operationID: operationID,
                level: outcome == "success" || outcome == "degraded" ? .info : .error
            )
        )
        await writeRuntimeSnapshot()
    }

    /// Stops background diagnostics work during application shutdown.
    public func shutdown() {
        rollupTask?.cancel()
        rollupTask = nil
        uploadTask?.cancel()
        uploadTask = nil
    }

    /// Checks whether automatic recovery is still allowed for a subsystem.
    public func canAttemptRecovery(subsystem: RecoverySubsystem) -> Bool {
        pruneRecoveryWindow()
        let attempts = recoveryAttempts[subsystem] ?? []
        return attempts.count < 5
    }

    /// Records an automatic recovery attempt and result.
    public func recordRecoveryAttempt(subsystem: RecoverySubsystem, reason: String, success: Bool) async {
        pruneRecoveryWindow()
        recoveryAttempts[subsystem, default: []].append(Date())

        await recordMetric(
            MetricPoint(
                name: "recovery_attempt_total",
                value: 1,
                tags: [
                    "subsystem": subsystem.rawValue,
                    "reason": reason
                ]
            )
        )

        if success {
            await recordMetric(
                MetricPoint(
                    name: "recovery_success_total",
                    value: 1,
                    tags: [
                        "subsystem": subsystem.rawValue,
                        "reason": reason
                    ]
                )
            )
        }
    }

    /// Starts optional periodic upload loop for aggregated telemetry.
    public func startUploadLoop(optedIn: Bool) {
        uploadTask?.cancel()
        guard optedIn, uploadEndpoint != nil else {
            return
        }

        uploadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard let self else {
                    return
                }
                await self.uploadRollup()
            }
        }
    }

    /// Exports diagnostics bundle and returns archive URL.
    public func exportDiagnosticsBundle() async throws -> URL {
        let root = await historyStore.storageBasePath()
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archive = exports.appendingPathComponent("diagnostics-\(formatter.string(from: Date())).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        var inputs = ["db", "logs"]
        let runtimeState = root.appendingPathComponent("runtime-state.json")
        if FileManager.default.fileExists(atPath: runtimeState.path) {
            inputs.append(runtimeState.lastPathComponent)
        }
        process.arguments = ["-r", archive.path] + inputs
        process.currentDirectoryURL = root

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return archive
            }
            throw NSError(domain: "DiagnosticsCenter", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "zip command failed"])
        } catch {
            throw error
        }
    }

    private func pruneRecoveryWindow() {
        let cutoff = Date().addingTimeInterval(-600)
        for key in recoveryAttempts.keys {
            let filtered = recoveryAttempts[key, default: []].filter { $0 >= cutoff }
            recoveryAttempts[key] = filtered
        }
    }

    private func metricKey(name: String, tags: [String: String]) -> String {
        let suffix = tags.keys.sorted().map { "\($0)=\(tags[$0] ?? "")" }.joined(separator: ",")
        return "\(name){\(suffix)}"
    }

    private func startRollupLoop() {
        guard rollupTask == nil else {
            return
        }

        rollupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else {
                    return
                }
                await self.flushRollup()
            }
        }
    }

    private func flushRollup() async {
        guard !counterRollup.isEmpty else {
            return
        }

        for (key, value) in counterRollup {
            await logger.log(.info, "metrics_rollup_1m", metadata: ["metric": key, "value": String(value)])
        }

        counterRollup.removeAll(keepingCapacity: true)
    }

    private func uploadRollup() async {
        guard let endpoint = uploadEndpoint else {
            return
        }

        let payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "metrics": counterRollup
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let delays: [Duration] = [.seconds(1), .seconds(5), .seconds(30)]

        for delay in delays {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                await logger.log(.warning, "telemetry_upload_failed", metadata: ["error": String(describing: error)])
            }
            try? await Task.sleep(for: delay)
        }
    }

    private func inspectPreviousRuntime() async {
        let root = await historyStore.storageBasePath()
        let url = root.appendingPathComponent("runtime-state.json")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            await writeRuntimeSnapshot()
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let previous = try? decoder.decode(RuntimeDiagnosticsSnapshot.self, from: data) else {
            await writeRuntimeSnapshot()
            return
        }

        guard previous.status == "active" || previous.status == "stalled" else {
            runtimeSessionID = previous.sessionID
            runtimeOperationID = previous.operationID
            runtimePhase = "booting"
            runtimeStage = "startup"
            runtimeDetails = ["previous_status": previous.status]
            await writeRuntimeSnapshot()
            return
        }

        var attributes = [
            "previous_status": previous.status,
            "previous_phase": previous.phase,
            "previous_stage": previous.stage,
            "age_ms": String(Int(max(0, Date().timeIntervalSince(previous.updatedAt)) * 1000))
        ]
        attributes["previous_process_id"] = String(previous.processID)

        await emit(
            DiagnosticEvent(
                name: "previous_run_interrupted",
                sessionID: previous.sessionID,
                attributes: attributes,
                operationID: previous.operationID,
                level: .error
            )
        )

        if let sessionID = previous.sessionID {
            try? await historyStore.markProcessingSessionInterrupted(sessionID: sessionID)
        }

        runtimeStatus = "idle"
        runtimeSessionID = previous.sessionID
        runtimeOperationID = previous.operationID
        runtimePhase = "booting"
        runtimeStage = "startup_after_interruption"
        runtimeSessionStartedAt = nil
        runtimeLastProgressAt = nil
        runtimeDetails = attributes
        await writeRuntimeSnapshot()
    }

    private func writeRuntimeSnapshot() async {
        let root = await historyStore.storageBasePath()
        let url = root.appendingPathComponent("runtime-state.json")
        let snapshot = makeRuntimeSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            return
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            await logger.log(
                .warning,
                "Failed to write runtime diagnostics snapshot",
                metadata: ["error_code": "runtime_snapshot_write_failed"]
            )
        }
    }

    private func acceptsActiveSessionTrace(sessionID: UUID, operationID: UUID?) -> Bool {
        guard
            (runtimeStatus == "active" || runtimeStatus == "stalled"),
            runtimeSessionID == sessionID
        else {
            return false
        }

        guard let operationID else {
            return true
        }
        return runtimeOperationID == operationID
    }

    private func diagnosticPersistenceAttributes(for error: Error) -> [String: String] {
        if let historyError = error as? HistoryStoreError {
            switch historyError {
            case .databaseOpenFailed:
                return ["error_code": "database_open_failed"]
            case .sqlError:
                return ["error_code": "sql_error"]
            case .legacySourceMissing:
                return ["error_code": "legacy_source_missing"]
            case .transcriptNotFound:
                return ["error_code": "transcript_not_found"]
            }
        }

        return [
            "error_code": "unknown",
            "error_type": String(reflecting: type(of: error))
        ]
    }

    private func makeRuntimeSnapshot() -> RuntimeDiagnosticsSnapshot {
        RuntimeDiagnosticsSnapshot(
            status: runtimeStatus,
            sessionID: runtimeSessionID,
            operationID: runtimeOperationID,
            phase: runtimePhase,
            stage: runtimeStage,
            sessionStartedAt: runtimeSessionStartedAt,
            lastProgressAt: runtimeLastProgressAt,
            details: runtimeDetails.merging([
                "last_event": runtimeLastEvent ?? "none"
            ]) { current, _ in current }
        )
    }
}
