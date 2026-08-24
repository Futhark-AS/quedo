import Foundation
import QuedoCore

/// Application coordinator actor and single lifecycle owner.
actor AppControllerActor {
    private enum WorkflowAction {
        case starting
        case stopping
        case retrying
        case cancelling
    }

    private let configurationManager: ConfigurationManager
    private let lifecycle: LifecycleStateMachine
    private let permissionCoordinator: PermissionCoordinator
    private let audioEngine: AudioCaptureEngine
    private let transcriptionPipeline: TranscriptionPipeline
    private let outputRouter: OutputRouter
    private let historyStore: HistoryStore
    private let diagnostics: DiagnosticsCenter
    private let hotkeyManager: HotkeyManager
    private let onboardingCoordinator: OnboardingCoordinator

    private let uiUpdate: @MainActor @Sendable (AppLifecycleSnapshot, UIStateContract) -> Void

    private var settings: AppSettings = .default
    private var isRecording = false
    private var latestAudio: AudioCaptureResult?
    private var latestAudioSettings: AppSettings?
    private var latestAudioModelOverrides = TranscriptionModelOverrides()
    private var activeRecordingProfile: RecordingShortcutProfile?
    private var latestErrorDetail: String?
    private var latestRetryContext: TranscriptionRetryContext?
    private var latestOutputText: String?

    private struct TranscriptionRetryContext {
        let settings: AppSettings
        let modelOverrides: TranscriptionModelOverrides
        let createdAt: Date
    }
    private var workflowAction: WorkflowAction?

    private var workflowWatchdogTask: Task<Void, Never>?
    private var workflowSessionID: UUID?
    private var workflowOperationID: UUID?
    private var workflowStartedAt: Date?
    private var workflowLastProgressAt: Date?
    private var workflowStage = "idle"
    private var workflowStallReported = false
    private var workflowAudioErrorReported = false

    init(
        configurationManager: ConfigurationManager,
        lifecycle: LifecycleStateMachine,
        permissionCoordinator: PermissionCoordinator,
        audioEngine: AudioCaptureEngine,
        transcriptionPipeline: TranscriptionPipeline,
        outputRouter: OutputRouter,
        historyStore: HistoryStore,
        diagnostics: DiagnosticsCenter,
        hotkeyManager: HotkeyManager,
        onboardingCoordinator: OnboardingCoordinator,
        uiUpdate: @escaping @MainActor @Sendable (AppLifecycleSnapshot, UIStateContract) -> Void
    ) {
        self.configurationManager = configurationManager
        self.lifecycle = lifecycle
        self.permissionCoordinator = permissionCoordinator
        self.audioEngine = audioEngine
        self.transcriptionPipeline = transcriptionPipeline
        self.outputRouter = outputRouter
        self.historyStore = historyStore
        self.diagnostics = diagnostics
        self.hotkeyManager = hotkeyManager
        self.onboardingCoordinator = onboardingCoordinator
        self.uiUpdate = uiUpdate
    }

    func boot() async {
        let bootOperationID = UUID()
        await diagnostics.beginApplicationTrace(
            operationID: bootOperationID,
            stage: "controller_boot_started",
            details: ["process_id": String(ProcessInfo.processInfo.processIdentifier)]
        )
        await diagnostics.emit(
            DiagnosticEvent(
                name: "controller_boot_started",
                sessionID: nil,
                attributes: [:],
                operationID: bootOperationID
            )
        )
        do {
            await diagnostics.markApplicationProgress(operationID: bootOperationID, stage: "settings_loading")
            settings = try await configurationManager.loadSettings()
            await diagnostics.markApplicationProgress(operationID: bootOperationID, stage: "hotkeys_registering")
            try await applyHotkeyBindings()

            await diagnostics.markApplicationProgress(operationID: bootOperationID, stage: "audio_engine_preparing")
            await audioEngine.prepareEngine()
            await diagnostics.markApplicationProgress(operationID: bootOperationID, stage: "permissions_checking")
            let permissionSnapshot = await permissionCoordinator.checkAll()

            if !permissionsSatisfyRuntimeRequirements(permissionSnapshot) {
                try await lifecycle.transition(to: .degraded, degradedReason: .permissions)
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "degraded_enter_total",
                        sessionID: nil,
                        attributes: ["reason": "permissions"],
                        operationID: bootOperationID
                    )
                )
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "controller_boot_completed",
                        sessionID: nil,
                        attributes: ["phase": "degraded", "reason": "permissions"],
                        operationID: bootOperationID
                    )
                )
                await diagnostics.endApplicationTrace(
                    operationID: bootOperationID,
                    outcome: "degraded",
                    phase: "degraded",
                    stage: "permissions_degraded",
                    details: ["reason": "permissions"]
                )
                await pushUI()
                return
            }

            await diagnostics.markApplicationProgress(operationID: bootOperationID, stage: "onboarding_checking")
            if await onboardingCoordinator.requiresOnboarding() {
                try await lifecycle.transition(to: .onboarding)
                await pushUI()
                await diagnostics.markApplicationProgress(operationID: bootOperationID, stage: "onboarding_reliability_gates")
                let result = await onboardingCoordinator.runReliabilityGates(
                    settings: settings,
                    hotkeyManager: hotkeyManager,
                    audioEngine: audioEngine,
                    pipeline: transcriptionPipeline
                )
                if result.passed {
                    try await lifecycle.transition(to: .ready)
                } else {
                    try await lifecycle.transition(to: .degraded, degradedReason: result.degradedReason)
                }
                let phase = result.passed ? "ready" : "degraded"
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "controller_boot_completed",
                        sessionID: nil,
                        attributes: ["phase": phase, "onboarding": "true"],
                        operationID: bootOperationID
                    )
                )
                await diagnostics.endApplicationTrace(
                    operationID: bootOperationID,
                    outcome: result.passed ? "success" : "degraded",
                    phase: phase,
                    stage: result.passed ? "ready" : "onboarding_degraded",
                    details: ["onboarding": "true"]
                )
                await pushUI()
                return
            }

            try await lifecycle.transition(to: .ready)
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "controller_boot_completed",
                    sessionID: nil,
                    attributes: ["phase": "ready"],
                    operationID: bootOperationID
                )
            )
            await diagnostics.endApplicationTrace(
                operationID: bootOperationID,
                outcome: "success",
                phase: "ready",
                stage: "ready"
            )
            await pushUI()
        } catch {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "controller_boot_failed",
                    sessionID: nil,
                    attributes: diagnosticAttributes(for: error).merging([
                        "reason": "internal_error"
                    ]) { current, _ in current },
                    operationID: bootOperationID,
                    level: .error
                )
            )
            do {
                try await lifecycle.transition(to: .degraded, degradedReason: .internalError)
            } catch {
                // Keep current phase if transition fails.
            }
            await diagnostics.endApplicationTrace(
                operationID: bootOperationID,
                outcome: "failed",
                phase: "degraded",
                stage: "controller_boot_failed",
                details: diagnosticAttributes(for: error)
            )
            await pushUI()
        }
    }

    func reloadSettingsFromDisk() async {
        do {
            settings = try await configurationManager.loadSettings()
            try await applyHotkeyBindings()
            await diagnostics.emit(
                DiagnosticEvent(name: "settings_reloaded", sessionID: nil, attributes: ["source": "preferences"])
            )
            let recovered = await recoverFromPermissionDegradedStateIfPossible()
            if !recovered {
                await pushUI()
            }
        } catch {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "settings_reload_failed",
                    sessionID: nil,
                    attributes: diagnosticAttributes(for: error),
                    level: .error
                )
            )
        }
    }

    func handleMenuAction(_ action: AppAction) async {
        await diagnostics.emit(
            DiagnosticEvent(
                name: "menu_action_requested",
                sessionID: (await lifecycle.snapshot()).currentSessionID,
                attributes: ["action": action.rawValue],
                level: .debug
            )
        )

        switch action {
        case .startRecording:
            await startRecordingFlow()
        case .stop:
            await stopRecordingFlow()
        case .forceStop:
            await cancelFlow()
        case .cancel:
            await cancelFlow()
        case .retry:
            await retryFlow()
        case .switchProvider:
            await switchProviderFlow()
        case .useClipboardOnly:
            settings.outputMode = .clipboard
            do {
                try await configurationManager.saveSettings(settings)
                let permissions = await permissionCoordinator.checkAll()
                if permissionsSatisfyRuntimeRequirements(permissions) {
                    await lifecycle.setLastErrorCode(nil)
                    try await lifecycle.transition(to: .ready)
                } else {
                    await lifecycle.setLastErrorCode("permissions_not_ready")
                    try await lifecycle.transition(to: .degraded, degradedReason: .permissions)
                }
            } catch {
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "settings_save_error",
                        sessionID: nil,
                        attributes: diagnosticAttributes(for: error),
                        level: .error
                    )
                )
            }
            await pushUI()
        case .refreshDevices:
            await audioEngine.prepareEngine()
            await pushUI()
        case .runChecks:
            await runChecksFlow()
        case .retryRegistration, .rebindHotkey:
            await retryHotkeyRegistrationFlow()
        default:
            await diagnostics.emit(
                DiagnosticEvent(name: "menu_action", sessionID: nil, attributes: ["action": action.rawValue])
            )
        }
    }

    func lastErrorDescription() async -> String {
        let snapshot = await lifecycle.snapshot()
        guard let code = snapshot.lastErrorCode else {
            if let degradedReason = snapshot.degradedReason {
                let mapped = messageForDegradedReason(degradedReason)
                return "\(mapped)\n\nTechnical: phase \(snapshot.phase.rawValue), reason \(degradedReason.rawValue)"
            }
            return "No recent error recorded."
        }

        let mapped = latestErrorDetail ?? messageForErrorCode(code)
        let degraded = snapshot.degradedReason?.rawValue ?? "none"
        return "\(mapped)\n\nTechnical: code \(code), phase \(snapshot.phase.rawValue), degraded \(degraded)"
    }

    func handleHotkey(actionID: String, event: HotkeyEvent) async {
        let snapshot = await lifecycle.snapshot()
        if event == .pressed {
            await diagnostics.recordMetric(
                MetricPoint(
                    name: "hotkey_trigger_total",
                    value: 1,
                    tags: ["action": actionID],
                    sessionID: snapshot.currentSessionID
                )
            )
        }

        await diagnostics.emit(
            DiagnosticEvent(
                name: "hotkey_event_received",
                sessionID: snapshot.currentSessionID,
                attributes: [
                    "action": actionID,
                    "event": event.rawValue,
                    "phase": snapshot.phase.rawValue,
                    "is_recording": isRecording ? "true" : "false"
                ],
                level: .debug
            )
        )

        switch actionID {
        case "toggle":
            let command = HotkeyRouting.toggleCommand(
                mode: settings.recordingInteraction,
                event: event,
                phase: snapshot.phase,
                isRecording: isRecording,
                hasActiveSession: snapshot.currentSessionID != nil
            )
            switch command {
            case .start:
                await startRecordingFlow()
            case .stop:
                await stopRecordingFlow()
            case .cancelArming:
                await cancelFlow()
            case .none:
                return
            }
        case let profileAction where profileAction.hasPrefix("recording."):
            guard let profile = settings.recordingProfiles.first(where: { $0.actionID == profileAction }) else {
                return
            }
            let command = HotkeyRouting.toggleCommand(
                mode: settings.recordingInteraction,
                event: event,
                phase: snapshot.phase,
                isRecording: isRecording,
                hasActiveSession: snapshot.currentSessionID != nil
            )
            switch command {
            case .start:
                await startRecordingFlow(profile: profile)
            case .stop:
                await stopRecordingFlow()
            case .cancelArming:
                await cancelFlow()
            case .none:
                return
            }
        case "retry":
            guard event == .pressed else {
                return
            }
            await retryFlow()
        case "cancel":
            guard event == .pressed else {
                return
            }
            await cancelFlow()
        default:
            break
        }
    }

    func shutdown() async {
        await diagnostics.emit(
            DiagnosticEvent(
                name: "app_shutdown_requested",
                sessionID: workflowSessionID,
                attributes: [:]
            )
        )
        await audioEngine.cancelRecording()
        hotkeyManager.deactivate()
        await transcriptionPipeline.shutdown()
        await endWorkflowTrace(outcome: "cancelled", phase: "shutting_down", stage: "shutdown")
        try? await lifecycle.transition(to: .shuttingDown)
        await pushUI()
        await diagnostics.shutdown()
    }

    func refreshPermissionStateAfterActivation() async {
        _ = await recoverFromPermissionDegradedStateIfPossible()
    }

    private func startRecordingFlow(profile: RecordingShortcutProfile? = nil) async {
        if workflowAction != nil {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_start_ignored",
                    sessionID: workflowSessionID,
                    attributes: ["reason": "workflow_in_flight"],
                    level: .debug
                )
            )
            return
        }
        if isRecording {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_start_ignored",
                    sessionID: workflowSessionID,
                    attributes: ["reason": "already_recording"],
                    level: .debug
                )
            )
            return
        }
        let snapshot = await lifecycle.snapshot()
        guard snapshot.currentSessionID == nil else {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_start_ignored",
                    sessionID: snapshot.currentSessionID,
                    attributes: [
                        "reason": "session_already_active",
                        "phase": snapshot.phase.rawValue
                    ],
                    level: .debug
                )
            )
            return
        }

        let sessionID = UUID()
        let operationID = UUID()
        workflowAction = .starting
        workflowSessionID = sessionID
        workflowOperationID = operationID
        workflowStartedAt = Date()
        workflowLastProgressAt = workflowStartedAt
        workflowStage = "start_requested"
        do {
            latestErrorDetail = nil
            try await lifecycle.beginSession(id: sessionID)
            guard workflowAction == .starting, isWorkflowActive(operationID) else {
                if isWorkflowActive(operationID) {
                    await audioEngine.cancelRecording()
                    await lifecycle.endSession()
                }
                return
            }
            activeRecordingProfile = profile
            let recordingSettings = settingsForActiveRecordingProfile()
            let traceStarted = await beginWorkflowTrace(
                sessionID: sessionID,
                operationID: operationID,
                phase: snapshot.phase.rawValue,
                stage: "start_requested",
                details: profile.map { ["profile": $0.id] } ?? [:],
                providerPrimary: recordingSettings.provider.primary,
                language: recordingSettings.language,
                outputMode: recordingSettings.outputMode
            )
            guard traceStarted, workflowAction == .starting, isWorkflowActive(operationID) else {
                if isWorkflowActive(operationID) {
                    await audioEngine.cancelRecording()
                    await lifecycle.endSession()
                }
                return
            }
            await markWorkflowProgress(stage: "arming_requested", phase: "arming")
            try await lifecycle.transition(to: .arming)
            guard isWorkflowActive(operationID), workflowAction == .starting else {
                if isWorkflowActive(operationID) {
                    await audioEngine.cancelRecording()
                }
                return
            }
            await pushUI()

            await markWorkflowProgress(stage: "audio_start_requested", phase: "arming")
            try await audioEngine.startRecording(sessionID: sessionID)
            guard isWorkflowActive(operationID), workflowAction == .starting else {
                if isWorkflowActive(operationID) {
                    await audioEngine.cancelRecording()
                }
                return
            }
            await markWorkflowProgress(stage: "audio_started_waiting_for_first_frame", phase: "arming")
            let armed = await audioEngine.waitForFirstFrame(timeout: .seconds(5))
            guard isWorkflowActive(operationID), workflowAction == .starting else {
                if isWorkflowActive(operationID) {
                    await audioEngine.cancelRecording()
                }
                return
            }
            guard armed else {
                let postArmSnapshot = await lifecycle.snapshot()
                if postArmSnapshot.currentSessionID == nil || postArmSnapshot.phase == .ready {
                    await diagnostics.emit(
                        DiagnosticEvent(
                            name: "session_start_cancelled",
                            sessionID: sessionID,
                            attributes: ["reason": "cancelled_during_arming"],
                            operationID: operationID
                        )
                    )
                    await endWorkflowTrace(
                        operationID: operationID,
                        outcome: "cancelled",
                        phase: postArmSnapshot.phase.rawValue,
                        stage: "arming_cancelled"
                    )
                    return
                }
                throw AudioCaptureError.streamOpenFailed
            }

            await markWorkflowProgress(stage: "first_audio_frame_received", phase: "arming")
            try await lifecycle.transition(to: .recording)
            guard isWorkflowActive(operationID), workflowAction == .starting else {
                if isWorkflowActive(operationID) {
                    await audioEngine.cancelRecording()
                }
                return
            }
            isRecording = true
            workflowAction = nil
            await markWorkflowProgress(stage: "recording", phase: "recording")
            await diagnostics.recordMetric(
                MetricPoint(
                    name: "session_start_total",
                    value: 1,
                    tags: [:],
                    sessionID: sessionID,
                    operationID: operationID
                )
            )
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "recording_started",
                    sessionID: sessionID,
                    attributes: (profile.map { ["profile": $0.id] } ?? [:]).merging([
                        "audio_confirmed": "true"
                    ]) { current, _ in current },
                    operationID: operationID
                )
            )
            await pushUI()
        } catch let error as AudioCaptureError {
            guard isWorkflowActive(operationID), workflowAction == .starting else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "stale_audio_start_error")
                return
            }
            await audioEngine.cancelRecording()
            isRecording = false
            activeRecordingProfile = nil
            let degraded: DegradedReason = (error == .noInputDevice) ? .noInputDevice : .internalError
            try? await lifecycle.transition(to: .degraded, degradedReason: degraded)
            await lifecycle.setLastErrorCode("capture_open_failed")
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_start_failed",
                    sessionID: sessionID,
                    attributes: diagnosticAttributes(for: error),
                    operationID: operationID,
                    level: .error
                )
            )
            await diagnostics.recordMetric(
                MetricPoint(
                    name: "session_start_failed_total",
                    value: 1,
                    tags: ["reason": error.diagnosticCode],
                    sessionID: sessionID,
                    operationID: operationID
                )
            )
            await pushUI()
            await lifecycle.endSession()
            try? await historyStore.updateSessionStatus(sessionID: sessionID, status: .failed)
            await endWorkflowTrace(operationID: operationID, outcome: "failed", phase: degraded.rawValue, stage: "start_failed")
        } catch {
            if let transitionError = error as? StateTransitionError,
               transitionError.reason == "Only one active session is allowed"
            {
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "session_start_ignored",
                        sessionID: nil,
                        attributes: ["reason": "session_already_active"],
                        operationID: operationID,
                        level: .debug
                    )
                )
                await endWorkflowTrace(operationID: operationID, outcome: "cancelled", phase: snapshot.phase.rawValue, stage: "start_rejected")
                return
            }
            guard isWorkflowActive(operationID), workflowAction == .starting else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "stale_start_error")
                return
            }
            await audioEngine.cancelRecording()
            isRecording = false
            activeRecordingProfile = nil
            try? await lifecycle.transition(to: .degraded, degradedReason: .internalError)
            await lifecycle.setLastErrorCode("capture_open_failed")
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_start_failed",
                    sessionID: sessionID,
                    attributes: diagnosticAttributes(for: error),
                    operationID: operationID,
                    level: .error
                )
            )
            await pushUI()
            await lifecycle.endSession()
            try? await historyStore.updateSessionStatus(sessionID: sessionID, status: .failed)
            await endWorkflowTrace(operationID: operationID, outcome: "failed", phase: "degraded", stage: "start_failed")
        }
    }

    private func stopRecordingFlow() async {
        if workflowAction != nil {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_stop_ignored",
                    sessionID: workflowSessionID,
                    attributes: ["reason": "workflow_in_flight"],
                    level: .debug
                )
            )
            return
        }
        guard isRecording else {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_stop_ignored",
                    sessionID: workflowSessionID,
                    attributes: ["reason": "not_recording"],
                    level: .debug
                )
            )
            return
        }
        guard let operationID = workflowOperationID else {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_stop_ignored",
                    sessionID: nil,
                    attributes: ["reason": "missing_operation_trace"],
                    level: .error
                )
            )
            return
        }

        guard let sessionID = workflowSessionID else {
            workflowAction = nil
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_stop_ignored",
                    sessionID: nil,
                    attributes: ["reason": "missing_session_trace"],
                    level: .error
                )
            )
            return
        }
        workflowAction = .stopping
        let stopStartedAt = Date()
        await markWorkflowProgress(stage: "stop_requested", phase: "recording")
        var failureStage = "audio capture"
        var rawCaptureForRecovery: AudioCaptureResult?
        var persistedCapture: AudioCaptureResult?
        var transcriptionSettings = settingsForActiveRecordingProfile()
        var transcriptionOverrides = modelOverridesForActiveRecordingProfile()
        do {
            try await lifecycle.transition(to: .processing)
            await pushUI()

            await markWorkflowProgress(stage: "audio_stop_requested", phase: "processing")
            let rawCapture = try await audioEngine.stopRecording()
            rawCaptureForRecovery = rawCapture
            isRecording = false
            transcriptionSettings = settingsForActiveRecordingProfile()
            transcriptionOverrides = modelOverridesForActiveRecordingProfile()
            latestAudioSettings = transcriptionSettings
            latestAudioModelOverrides = transcriptionOverrides
            await markWorkflowProgress(
                stage: "audio_finalized",
                phase: "processing",
                details: [
                    "duration_ms": String(rawCapture.durationMS),
                    "audio_bytes": String(audioFileSize(rawCapture.fileURL)),
                    "stop_elapsed_ms": String(Int(Date().timeIntervalSince(stopStartedAt) * 1000))
                ]
            )
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "audio_finalized")
                return
            }

            let start = Date()
            transcriptionSettings = settingsForActiveRecordingProfile()
            transcriptionOverrides = modelOverridesForActiveRecordingProfile()
            let capturedAt = Date()

            failureStage = "history pre-save"
            let pendingRecord = SessionRecord(
                sessionID: sessionID,
                createdAt: capturedAt,
                durationMS: rawCapture.durationMS,
                providerPrimary: transcriptionSettings.provider.primary,
                providerUsed: transcriptionSettings.provider.primary,
                language: transcriptionSettings.language,
                outputMode: settings.outputMode,
                status: .retryAvailable,
                transcript: "",
                audioPath: rawCapture.fileURL
            )
            let durableAudioURL = try await historyStore.saveSession(pendingRecord)
            let capture = AudioCaptureResult(
                sessionID: sessionID,
                fileURL: durableAudioURL,
                durationMS: rawCapture.durationMS
            )
            latestAudio = capture
            persistedCapture = capture
            latestRetryContext = TranscriptionRetryContext(
                settings: transcriptionSettings,
                modelOverrides: transcriptionOverrides,
                createdAt: capturedAt
            )
            latestOutputText = nil

            failureStage = "transcription"
            await markWorkflowProgress(
                stage: "transcription_requested",
                phase: "processing",
                details: [
                    "primary_provider": transcriptionSettings.provider.primary.rawValue,
                    "fallback_provider": transcriptionSettings.provider.fallback.rawValue
                ]
            )
            let pipelineResult = try await transcriptionPipeline.transcribe(
                audioFileURL: capture.fileURL,
                settings: transcriptionSettings,
                modelOverrides: transcriptionOverrides,
                sessionID: capture.sessionID,
                operationID: operationID
            )
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "transcription_completed")
                return
            }

            if pipelineResult.fallbackUsed {
                try? await lifecycle.transition(to: .providerFallback)
                await markWorkflowProgress(stage: "fallback_completed", phase: "providerFallback")
                await pushUI()
                await lifecycle.markFallbackAttempted()
            }

            failureStage = "history save"
            await markWorkflowProgress(stage: "history_persist_requested", phase: "outputting")
            let record = SessionRecord(
                sessionID: sessionID,
                createdAt: capturedAt,
                durationMS: capture.durationMS,
                providerPrimary: transcriptionSettings.provider.primary,
                providerUsed: pipelineResult.providerUsed,
                language: transcriptionSettings.language,
                outputMode: settings.outputMode,
                status: .success,
                transcript: pipelineResult.text,
                audioPath: capture.fileURL
            )
            let finalAudioURL: URL
            do {
                finalAudioURL = try await historyStore.saveSession(record)
            } catch {
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "history_persist_failed",
                        sessionID: sessionID,
                        attributes: diagnosticAttributes(for: error),
                        operationID: operationID,
                        level: .error
                    )
                )
                throw error
            }
            latestAudio = AudioCaptureResult(
                sessionID: sessionID,
                fileURL: finalAudioURL,
                durationMS: capture.durationMS
            )
            latestOutputText = pipelineResult.text
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "history_persisted")
                return
            }
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "history_persisted",
                    sessionID: sessionID,
                    attributes: ["status": SessionStatus.success.rawValue],
                    operationID: operationID
                )
            )

            try await lifecycle.transition(to: .outputting)
            await pushUI()

            failureStage = "output"
            await markWorkflowProgress(stage: "output_requested", phase: "outputting")
            _ = try await outputRouter.route(text: pipelineResult.text, mode: settings.outputMode, profile: settings.buildProfile)
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "output_completed")
                return
            }
            await markWorkflowProgress(
                stage: "output_completed",
                phase: "outputting",
                details: ["output_mode": settings.outputMode.rawValue]
            )
            await diagnostics.recordMetric(
                MetricPoint(
                    name: "session_latency_stop_to_final_transcript_ms",
                    value: Date().timeIntervalSince(start) * 1000,
                    tags: [:],
                    sessionID: sessionID,
                    operationID: operationID
                )
            )

            try await lifecycle.transition(to: .ready)
            await lifecycle.endSession()
            activeRecordingProfile = nil
            latestErrorDetail = nil
            latestRetryContext = nil
            latestOutputText = nil
            latestAudio = nil
            latestAudioSettings = nil
            latestAudioModelOverrides = TranscriptionModelOverrides()
            await endWorkflowTrace(operationID: operationID, outcome: "success", phase: "ready", stage: "completed")
            await pushUI()
        } catch {
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "stale_error")
                return
            }
            isRecording = false
            let failedSettings = transcriptionSettings
            let failedOverrides = transcriptionOverrides
            var detail: String
            if failureStage == "transcription" {
                detail = transcriptionFailureMessage(error: error, settings: failedSettings, modelOverrides: failedOverrides)
            } else {
                detail = workflowFailureMessage(stage: failureStage, error: error)
            }

            let capturePreservedAt = Date()
            if failureStage == "audio capture",
               let recoverableCapture = await audioEngine.takeRecoverableCapture(),
               let preservedCapture = await preserveFailedCapture(
                   recoverableCapture,
                   settings: failedSettings,
                   createdAt: capturePreservedAt
               )
            {
                latestAudio = preservedCapture
                latestAudioSettings = failedSettings
                latestAudioModelOverrides = failedOverrides
                latestRetryContext = TranscriptionRetryContext(
                    settings: failedSettings,
                    modelOverrides: failedOverrides,
                    createdAt: capturePreservedAt
                )
                detail += "\n\nPartial audio captured before the microphone interruption was preserved and can be retried."
            }
            latestErrorDetail = detail
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "recording_flow_failed",
                    sessionID: latestAudio?.sessionID,
                    attributes: [
                        "stage": failureStage,
                        "primary": failedSettings.provider.primary.rawValue,
                        "fallback": failedSettings.provider.fallback.rawValue,
                        "error": sanitizedDiagnostic(error)
                    ]
                )
            )
            if failureStage == "transcription", let persistedCapture {
                let failedRecord = SessionRecord(
                    sessionID: persistedCapture.sessionID,
                    createdAt: latestRetryContext?.createdAt ?? Date(),
                    durationMS: persistedCapture.durationMS,
                    providerPrimary: failedSettings.provider.primary,
                    providerUsed: failedSettings.provider.primary,
                    language: failedSettings.language,
                    outputMode: settings.outputMode,
                    status: .retryAvailable,
                    transcript: "",
                    audioPath: persistedCapture.fileURL
                )
                _ = try? await historyStore.saveSession(failedRecord)
            }
            if failureStage == "history pre-save", let rawCaptureForRecovery {
                if let recoveredURL = recoverAudioForManualImport(rawCaptureForRecovery) {
                    latestAudio = AudioCaptureResult(
                        sessionID: rawCaptureForRecovery.sessionID,
                        fileURL: recoveredURL,
                        durationMS: rawCaptureForRecovery.durationMS
                    )
                    latestErrorDetail = "\(detail)\n\nRecovered audio copy:\n\(recoveredURL.path)"
                }
            }
            activeRecordingProfile = nil
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_failed",
                    sessionID: sessionID,
                    attributes: diagnosticAttributes(for: error).merging([
                        "stage": workflowStage,
                        "elapsed_ms": String(Int(Date().timeIntervalSince(stopStartedAt) * 1000))
                    ]) { current, _ in current },
                    operationID: operationID,
                    level: .error
                )
            )
            await diagnostics.recordMetric(
                MetricPoint(
                    name: "session_failed_total",
                    value: 1,
                    tags: ["stage": workflowStage],
                    sessionID: sessionID,
                    operationID: operationID
                )
            )
            try? await lifecycle.transition(to: .retryAvailable)
            await lifecycle.setLastErrorCode(errorCode(forFailureStage: failureStage, error: error))
            await lifecycle.endSession()
            try? await historyStore.updateSessionStatus(sessionID: sessionID, status: .retryAvailable)
            await endWorkflowTrace(operationID: operationID, outcome: "failed", phase: "retryAvailable", stage: "failed")
            await pushUI()
        }
    }

    private func retryFlow() async {
        if workflowAction != nil {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "retry_ignored",
                    sessionID: workflowSessionID,
                    attributes: ["reason": "workflow_in_flight"],
                    level: .debug
                )
            )
            return
        }
        guard let audio = latestAudio else {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "retry_ignored",
                    sessionID: nil,
                    attributes: ["reason": "no_latest_audio"],
                    level: .debug
                )
            )
            return
        }

        let sessionID = audio.sessionID
        let snapshot = await lifecycle.snapshot()
        if let activeSessionID = snapshot.currentSessionID, activeSessionID != sessionID {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "retry_ignored",
                    sessionID: activeSessionID,
                    attributes: ["reason": "different_session_active"],
                    level: .debug
                )
            )
            return
        }

        let operationID = UUID()
        let retrySettings = latestAudioSettings ?? settings
        let retryModelOverrides = latestAudioModelOverrides
        workflowAction = .retrying
        workflowSessionID = sessionID
        workflowOperationID = operationID
        workflowStartedAt = Date()
        workflowLastProgressAt = workflowStartedAt
        workflowStage = "retry_requested"
        if snapshot.currentSessionID == nil {
            do {
                try await lifecycle.beginSession(id: sessionID)
            } catch {
                workflowAction = nil
                workflowSessionID = nil
                workflowOperationID = nil
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "retry_ignored",
                        sessionID: sessionID,
                        attributes: ["reason": "session_begin_failed"].merging(diagnosticAttributes(for: error)) { current, _ in current },
                        operationID: operationID,
                        level: .error
                    )
                )
                return
            }
        }

        let traceStarted = await beginWorkflowTrace(
            sessionID: sessionID,
            operationID: operationID,
            phase: snapshot.phase.rawValue,
            stage: "retry_requested",
            providerPrimary: retrySettings.provider.primary,
            language: retrySettings.language,
            outputMode: retrySettings.outputMode
        )
        guard traceStarted, isWorkflowActive(operationID), workflowAction == .retrying else {
            return
        }

        let retrySnapshot = await lifecycle.snapshot()
        if retrySnapshot.lastErrorCode == "output_failed", let latestOutputText {
            do {
                try await lifecycle.transition(to: .outputting)
                await markWorkflowProgress(stage: "retry_output_requested", phase: "outputting")
                await pushUI()
                _ = try await outputRouter.route(text: latestOutputText, mode: settings.outputMode, profile: settings.buildProfile)
                try await lifecycle.transition(to: .ready)
                await lifecycle.endSession()
                latestErrorDetail = nil
                self.latestOutputText = nil
                self.latestAudio = nil
                latestAudioSettings = nil
                latestAudioModelOverrides = TranscriptionModelOverrides()
                await endWorkflowTrace(operationID: operationID, outcome: "success", phase: "ready", stage: "output_retry_completed")
                await pushUI()
            } catch {
                latestErrorDetail = workflowFailureMessage(stage: "output", error: error)
                await lifecycle.setLastErrorCode("output_failed")
                try? await lifecycle.transition(to: .retryAvailable)
                await lifecycle.endSession()
                await endWorkflowTrace(operationID: operationID, outcome: "failed", phase: "retryAvailable", stage: "output_retry_failed")
                await pushUI()
            }
            return
        }

        var failureStage = "transcription"
        let retryContext = latestRetryContext ?? TranscriptionRetryContext(
            settings: settings,
            modelOverrides: TranscriptionModelOverrides(),
            createdAt: Date()
        )

        do {
            await markWorkflowProgress(stage: "retry_transcription_requested", phase: "processing")
            try await lifecycle.transition(to: .processing)
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "retry_processing_started")
                return
            }
            await pushUI()

            let result = try await transcriptionPipeline.transcribe(
                audioFileURL: audio.fileURL,
                settings: retrySettings,
                modelOverrides: retryModelOverrides,
                sessionID: sessionID,
                operationID: operationID
            )
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "retry_transcription_completed")
                return
            }
            failureStage = "history save"
            let record = SessionRecord(
                sessionID: audio.sessionID,
                createdAt: retryContext.createdAt,
                durationMS: audio.durationMS,
                providerPrimary: retrySettings.provider.primary,
                providerUsed: result.providerUsed,
                language: retrySettings.language,
                outputMode: retrySettings.outputMode,
                status: .success,
                transcript: result.text,
                audioPath: audio.fileURL
            )
            let durableAudioURL: URL
            do {
                durableAudioURL = try await historyStore.saveSession(record)
            } catch {
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "history_persist_failed",
                        sessionID: sessionID,
                        attributes: diagnosticAttributes(for: error),
                        operationID: operationID,
                        level: .error
                    )
                )
                throw error
            }
            self.latestAudio = AudioCaptureResult(
                sessionID: audio.sessionID,
                fileURL: durableAudioURL,
                durationMS: audio.durationMS
            )
            latestOutputText = result.text
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "history_persisted",
                    sessionID: sessionID,
                    attributes: ["status": SessionStatus.success.rawValue, "source": "retry"],
                    operationID: operationID
                )
            )
            failureStage = "output"
            try await lifecycle.transition(to: .outputting)
            await markWorkflowProgress(stage: "retry_output_requested", phase: "outputting")
            await pushUI()

            _ = try await outputRouter.route(text: result.text, mode: retrySettings.outputMode, profile: retrySettings.buildProfile)
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "retry_output_completed")
                return
            }

            try await lifecycle.transition(to: .ready)
            await lifecycle.endSession()
            latestErrorDetail = nil
            latestRetryContext = nil
            latestOutputText = nil
            latestAudio = nil
            latestAudioSettings = nil
            latestAudioModelOverrides = TranscriptionModelOverrides()
            await endWorkflowTrace(operationID: operationID, outcome: "success", phase: "ready", stage: "retry_completed")
            await pushUI()
        } catch {
            guard isWorkflowActive(operationID) else {
                await recordStaleWorkflowDiscarded(sessionID: sessionID, operationID: operationID, stage: "retry_stale_error")
                return
            }
            if failureStage == "transcription" {
                latestErrorDetail = transcriptionFailureMessage(
                    error: error,
                    settings: retryContext.settings,
                    modelOverrides: retryContext.modelOverrides
                )
            } else {
                latestErrorDetail = workflowFailureMessage(stage: failureStage, error: error)
            }
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "retry_failed",
                    sessionID: sessionID,
                    attributes: diagnosticAttributes(for: error).merging([
                        "stage": failureStage,
                        "primary": retryContext.settings.provider.primary.rawValue,
                        "fallback": retryContext.settings.provider.fallback.rawValue,
                        "error": sanitizedDiagnostic(error)
                    ]) { current, _ in current },
                    operationID: operationID,
                    level: .error
                )
            )
            try? await lifecycle.transition(to: .retryAvailable)
            await lifecycle.setLastErrorCode(errorCode(forFailureStage: failureStage, error: error))
            await lifecycle.endSession()
            try? await historyStore.updateSessionStatus(sessionID: sessionID, status: .retryAvailable)
            await endWorkflowTrace(operationID: operationID, outcome: "failed", phase: "retryAvailable", stage: "retry_failed")
            await pushUI()
        }
    }

    private func cancelFlow() async {
        if case .some(.cancelling) = workflowAction {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "session_cancel_ignored",
                    sessionID: workflowSessionID,
                    attributes: ["reason": "cancellation_in_flight"],
                    level: .debug
                )
            )
            return
        }
        if workflowAction != nil || workflowSessionID != nil || isRecording {
            workflowAction = .cancelling
        }
        let snapshot = await lifecycle.snapshot()
        let sessionID = workflowSessionID ?? snapshot.currentSessionID
        await diagnostics.emit(
            DiagnosticEvent(
                name: "session_cancel_requested",
                sessionID: sessionID,
                attributes: ["phase": snapshot.phase.rawValue]
            )
        )
        await audioEngine.cancelRecording()
        isRecording = false
        activeRecordingProfile = nil
        if let sessionID {
            try? await historyStore.updateSessionStatus(sessionID: sessionID, status: .cancelled)
        }
        await endWorkflowTrace(outcome: "cancelled", phase: snapshot.phase.rawValue, stage: "cancelled")
        await lifecycle.endSession()
        try? await lifecycle.transition(to: .ready)
        await pushUI()
    }

    private func switchProviderFlow() async {
        let previous = settings
        settings.provider = ProviderConfiguration(
            primary: previous.provider.fallback,
            fallback: previous.provider.primary,
            groqAPIKeyRef: previous.provider.groqAPIKeyRef,
            openAIAPIKeyRef: previous.provider.openAIAPIKeyRef,
            azureSpeechAPIKeyRef: previous.provider.azureSpeechAPIKeyRef,
            openRouterAPIKeyRef: previous.provider.openRouterAPIKeyRef,
            elevenLabsAPIKeyRef: previous.provider.elevenLabsAPIKeyRef,
            timeoutSeconds: previous.provider.timeoutSeconds,
            groqModel: previous.provider.groqModel,
            openAIModel: previous.provider.openAIModel,
            azureSpeechEndpoint: previous.provider.azureSpeechEndpoint,
            azureSpeechModel: previous.provider.azureSpeechModel,
            openRouterModel: previous.provider.openRouterModel,
            whisperCppModelPath: previous.provider.whisperCppModelPath,
            whisperCppRuntime: previous.provider.whisperCppRuntime,
            elevenLabsModel: previous.provider.elevenLabsModel
        )

        do {
            try await configurationManager.saveSettings(settings)
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "provider_switched",
                    sessionID: nil,
                    attributes: [
                        "primary": settings.provider.primary.rawValue,
                        "fallback": settings.provider.fallback.rawValue
                    ]
                )
            )
            await runChecksFlow()
        } catch {
            settings = previous
            await lifecycle.setLastErrorCode("settings_save_error")
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "provider_switch_failed",
                    sessionID: nil,
                    attributes: diagnosticAttributes(for: error),
                    level: .error
                )
            )
            try? await lifecycle.transition(to: .degraded, degradedReason: .internalError)
            await pushUI()
        }
    }

    private func retryHotkeyRegistrationFlow() async {
        do {
            try await applyHotkeyBindings()
            await lifecycle.setLastErrorCode(nil)
            try? await lifecycle.transition(to: .ready)
        } catch {
            await lifecycle.setLastErrorCode("hotkey_registration_failed")
            try? await lifecycle.transition(to: .degraded, degradedReason: .hotkeyFailure)
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "hotkey_registration_retry_failed",
                    sessionID: nil,
                    attributes: diagnosticAttributes(for: error),
                    level: .error
                )
            )
        }
        await pushUI()
    }

    private func runChecksFlow() async {
        let permissions = await permissionCoordinator.checkAll()
        let connectivity = await transcriptionPipeline.connectivityCheck(primary: settings.provider.primary, fallback: settings.provider.fallback)

        var hotkeysReady = true
        do {
            try await applyHotkeyBindings()
        } catch {
            hotkeysReady = false
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "run_checks_hotkey_registration_failed",
                    sessionID: nil,
                    attributes: diagnosticAttributes(for: error),
                    level: .error
                )
            )
        }

        await diagnostics.emit(
            DiagnosticEvent(
                name: "run_checks_completed",
                sessionID: nil,
                attributes: [
                    "microphone": permissions.microphone.rawValue,
                    "accessibility": permissions.accessibility.rawValue,
                    "inputMonitoring": permissions.inputMonitoring.rawValue,
                    "providerPrimaryOK": connectivity.primaryOK ? "true" : "false",
                    "providerFallbackOK": connectivity.fallbackOK ? "true" : "false",
                    "hotkeysReady": hotkeysReady ? "true" : "false"
                ]
            )
        )

        if !permissionsSatisfyRuntimeRequirements(permissions) {
            await lifecycle.setLastErrorCode("permissions_not_ready")
            try? await lifecycle.transition(to: .degraded, degradedReason: .permissions)
            await pushUI()
            return
        }

        if !hotkeysReady {
            await lifecycle.setLastErrorCode("hotkey_registration_failed")
            try? await lifecycle.transition(to: .degraded, degradedReason: .hotkeyFailure)
            await pushUI()
            return
        }

        if !(connectivity.primaryOK || connectivity.fallbackOK) {
            await lifecycle.setLastErrorCode("provider_connectivity_failed")
            try? await lifecycle.transition(to: .degraded, degradedReason: .providerUnavailable)
            await pushUI()
            return
        }

        await lifecycle.setLastErrorCode(nil)
        try? await lifecycle.transition(to: .ready)
        await pushUI()
    }

    private func pushUI() async {
        let snapshot = await lifecycle.snapshot()
        let contract = await lifecycle.uiContract()
        await uiUpdate(snapshot, contract)
    }

    private func applyHotkeyBindings() async throws {
        try await hotkeyManager.setBindings(settings.hotkeys) { [weak self] action, event in
            Task {
                await self?.handleHotkey(actionID: action, event: event)
            }
        }
    }

    private func settingsForActiveRecordingProfile() -> AppSettings {
        guard let profile = activeRecordingProfile else {
            return settings
        }

        var effective = settings
        effective.language = profile.language
        effective.provider.primary = profile.provider
        effective.provider.fallback = profile.fallbackProvider

        switch profile.provider {
        case .groq:
            effective.provider.groqModel = profile.model
        case .openAI:
            effective.provider.openAIModel = profile.model
        case .azureSpeech:
            effective.provider.azureSpeechModel = profile.model
        case .openRouter:
            effective.provider.openRouterModel = profile.model
        case .whisperCpp:
            effective.provider.whisperCppModelPath = profile.model
        case .elevenLabs:
            effective.provider.elevenLabsModel = profile.model
        }

        return effective
    }

    private func modelOverridesForActiveRecordingProfile() -> TranscriptionModelOverrides {
        guard let profile = activeRecordingProfile else {
            return TranscriptionModelOverrides()
        }
        return TranscriptionModelOverrides(primaryModel: profile.model, fallbackModel: profile.fallbackModel)
    }

    private func permissionsSatisfyRuntimeRequirements(_ permissions: PermissionSnapshot) -> Bool {
        permissions.satisfiesRuntimeRequirements(outputMode: settings.outputMode, buildProfile: settings.buildProfile)
    }

    private func isWorkflowActive(_ operationID: UUID) -> Bool {
        guard workflowOperationID == operationID else {
            return false
        }
        if case .some(.cancelling) = workflowAction {
            return false
        }
        return true
    }

    private func recordStaleWorkflowDiscarded(sessionID: UUID?, operationID: UUID, stage: String) async {
        await diagnostics.emit(
            DiagnosticEvent(
                name: "stale_session_flow_discarded",
                sessionID: sessionID,
                attributes: ["stage": stage],
                operationID: operationID,
                level: .warning
            )
        )
    }

    private func beginWorkflowTrace(
        sessionID: UUID,
        operationID: UUID,
        phase: String,
        stage: String,
        details: [String: String] = [:],
        providerPrimary: ProviderKind = .groq,
        language: String = "auto",
        outputMode: OutputMode = .none
    ) async -> Bool {
        workflowWatchdogTask?.cancel()
        workflowSessionID = sessionID
        workflowOperationID = operationID
        workflowStartedAt = Date()
        workflowLastProgressAt = workflowStartedAt
        workflowStage = stage
        workflowStallReported = false
        workflowAudioErrorReported = false

        await diagnostics.beginSessionTrace(
            sessionID: sessionID,
            operationID: operationID,
            phase: phase,
            stage: stage,
            details: details,
            providerPrimary: providerPrimary,
            language: language,
            outputMode: outputMode
        )

        guard workflowOperationID == operationID else {
            return false
        }

        workflowWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else {
                    return
                }
                await self.checkWorkflowWatchdog()
            }
        }
        return true
    }

    private func markWorkflowProgress(
        stage: String,
        phase: String,
        details: [String: String] = [:]
    ) async {
        guard let sessionID = workflowSessionID else {
            return
        }

        workflowStage = stage
        workflowLastProgressAt = Date()
        await diagnostics.markSessionProgress(
            sessionID: sessionID,
            operationID: workflowOperationID,
            phase: phase,
            stage: stage,
            details: details
        )
    }

    private func endWorkflowTrace(
        operationID: UUID? = nil,
        outcome: String,
        phase: String,
        stage: String
    ) async {
        if let operationID, workflowOperationID != operationID {
            return
        }
        guard let sessionID = workflowSessionID else {
            workflowAction = nil
            return
        }

        let operationID = workflowOperationID
        workflowWatchdogTask?.cancel()
        workflowWatchdogTask = nil
        await diagnostics.endSessionTrace(
            sessionID: sessionID,
            operationID: operationID,
            outcome: outcome,
            phase: phase,
            stage: stage,
            details: [
                "elapsed_ms": String(Int(Date().timeIntervalSince(workflowStartedAt ?? Date()) * 1000))
            ]
        )

        workflowSessionID = nil
        workflowOperationID = nil
        workflowAction = nil
        workflowStartedAt = nil
        workflowLastProgressAt = nil
        workflowStage = "idle"
        workflowStallReported = false
        workflowAudioErrorReported = false
    }

    private func checkWorkflowWatchdog() async {
        guard let sessionID = workflowSessionID else {
            return
        }

        let lifecycleSnapshot = await lifecycle.snapshot()
        guard lifecycleSnapshot.currentSessionID == sessionID else {
            return
        }

        let runtimeSnapshot = await diagnostics.runtimeSnapshot()
        var phase = lifecycleSnapshot.phase
        let lastProgressAt = runtimeSnapshot.lastProgressAt ?? workflowLastProgressAt ?? Date()
        let stage = runtimeSnapshot.stage == "startup" ? workflowStage : runtimeSnapshot.stage

        if phase == .recording || phase == .recoveringAudio {
            let audio = await audioEngine.healthSnapshot()

            if audio.isRecovering {
                if phase == .recording {
                    try? await lifecycle.transition(to: .recoveringAudio)
                    phase = .recoveringAudio
                    await diagnostics.emit(
                        DiagnosticEvent(
                            name: "audio_capture_recovery_started",
                            sessionID: sessionID,
                            attributes: [
                                "reason": audio.recoveryReason ?? "unknown",
                                "attempt": String(audio.recoveryAttempt),
                                "engine_running": audio.engineRunning ? "true" : "false",
                                "writer_ready": audio.writerReady ? "true" : "false"
                            ],
                            operationID: workflowOperationID,
                            level: .warning
                        )
                    )
                }
                await markWorkflowProgress(
                    stage: "audio_recovering",
                    phase: phase.rawValue,
                    details: ["attempt": String(audio.recoveryAttempt)]
                )
                await pushUI()
                return
            }

            if phase == .recoveringAudio {
                if let pendingErrorCode = audio.pendingErrorCode {
                    if !workflowAudioErrorReported {
                        workflowAudioErrorReported = true
                        await diagnostics.emit(
                            DiagnosticEvent(
                                name: "audio_capture_error_detected",
                                sessionID: sessionID,
                                attributes: [
                                    "error_code": pendingErrorCode,
                                    "engine_running": audio.engineRunning ? "true" : "false",
                                    "writer_ready": audio.writerReady ? "true" : "false"
                                ],
                                operationID: workflowOperationID,
                                level: .error
                            )
                        )
                    }
                    if workflowAction == nil {
                        await diagnostics.emit(
                            DiagnosticEvent(
                                name: "audio_capture_recovery_exhausted",
                                sessionID: sessionID,
                                attributes: ["error_code": pendingErrorCode],
                                operationID: workflowOperationID,
                                level: .error
                            )
                        )
                        await stopRecordingFlow()
                    }
                    return
                }

                guard audio.lastFrameAt != nil else {
                    return
                }

                try? await lifecycle.transition(to: .recording)
                phase = .recording
                await markWorkflowProgress(
                    stage: "audio_recovered",
                    phase: phase.rawValue,
                    details: ["recovery_attempt": String(audio.recoveryAttempt)]
                )
                await diagnostics.emit(
                    DiagnosticEvent(
                        name: "audio_capture_recovered",
                        sessionID: sessionID,
                        attributes: [
                            "engine_running": audio.engineRunning ? "true" : "false",
                            "writer_ready": audio.writerReady ? "true" : "false"
                        ],
                        operationID: workflowOperationID
                    )
                )
                await pushUI()
                return
            }

            if let pendingErrorCode = audio.pendingErrorCode {
                if !workflowAudioErrorReported {
                    workflowAudioErrorReported = true
                    await diagnostics.emit(
                        DiagnosticEvent(
                            name: "audio_capture_error_detected",
                            sessionID: sessionID,
                            attributes: [
                                "error_code": pendingErrorCode,
                                "engine_running": audio.engineRunning ? "true" : "false",
                                "writer_ready": audio.writerReady ? "true" : "false"
                            ],
                            operationID: workflowOperationID,
                            level: .error
                        )
                    )
                }
                if workflowAction == nil {
                    await diagnostics.emit(
                        DiagnosticEvent(
                            name: "audio_capture_recovery_exhausted",
                            sessionID: sessionID,
                            attributes: ["error_code": pendingErrorCode],
                            operationID: workflowOperationID,
                            level: .error
                        )
                    )
                    await stopRecordingFlow()
                }
                return
            }

            if let lastFrameAt = audio.lastFrameAt,
               lastFrameAt.timeIntervalSince(lastProgressAt) >= 1
            {
                workflowLastProgressAt = lastFrameAt
                await diagnostics.markSessionProgress(
                    sessionID: sessionID,
                    operationID: workflowOperationID,
                    phase: phase.rawValue,
                    stage: "recording",
                    details: [
                        "audio_heartbeat": "true",
                        "engine_running": audio.engineRunning ? "true" : "false",
                        "writer_ready": audio.writerReady ? "true" : "false"
                    ]
                )
                return
            }
        }

        if phase == .recoveringAudio {
            return
        }

        let ageSeconds = Date().timeIntervalSince(lastProgressAt)
        guard ageSeconds >= workflowStallTimeout(for: phase), !workflowStallReported else {
            return
        }

        workflowStallReported = true
        var details = [
            "lifecycle_phase": phase.rawValue,
            "runtime_phase": runtimeSnapshot.phase,
            "runtime_stage": stage
        ]
        if phase == .recording {
            let audio = await audioEngine.healthSnapshot()
            details["engine_running"] = audio.engineRunning ? "true" : "false"
            details["writer_ready"] = audio.writerReady ? "true" : "false"
            details["pending_error"] = audio.pendingErrorCode ?? "none"
        }

        await diagnostics.recordSessionStall(
            sessionID: sessionID,
            operationID: workflowOperationID,
            phase: phase.rawValue,
            stage: stage,
            ageSeconds: ageSeconds,
            details: details
        )
    }

    private func workflowStallTimeout(for phase: AppPhase) -> TimeInterval {
        switch phase {
        case .arming:
            return 8
        case .recording:
            return 8
        case .recoveringAudio:
            return 10
        case .processing, .providerFallback:
            return max(90, TimeInterval(settings.provider.timeoutSeconds * 10))
        case .outputting:
            return 20
        case .streamingPartial:
            return 30
        default:
            return 60
        }
    }

    private func audioFileSize(_ url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private func diagnosticAttributes(for error: Error) -> [String: String] {
        if let providerError = error as? ProviderError {
            return providerError.diagnosticAttributes
        }

        if let pipelineError = error as? TranscriptionPipelineError {
            var attributes = ["error_code": pipelineError.diagnosticCode]
            switch pipelineError {
            case let .providerUnavailable(provider):
                attributes["provider"] = provider.rawValue
            case let .retryAvailable(primary, fallback, _, _):
                attributes["primary"] = primary.rawValue
                attributes["fallback"] = fallback.rawValue
            case .chunkingFailed:
                break
            }
            return attributes
        }

        if let audioError = error as? AudioCaptureError {
            return ["error_code": audioError.diagnosticCode]
        }

        if let outputError = error as? OutputRouterError {
            return ["error_code": outputError.diagnosticCode]
        }

        if let transitionError = error as? StateTransitionError {
            return [
                "error_code": "state_transition_rejected",
                "from": transitionError.from.rawValue,
                "to": transitionError.to.rawValue,
                "reason": transitionError.reason
            ]
        }

        if let nsError = error as NSError? {
            return [
                "error_code": "unknown",
                "error_domain": nsError.domain,
                "error_number": String(nsError.code)
            ]
        }

        return [
            "error_code": "unknown",
            "error_type": String(reflecting: type(of: error))
        ]
    }

    @discardableResult
    private func recoverFromPermissionDegradedStateIfPossible() async -> Bool {
        let snapshot = await lifecycle.snapshot()
        guard snapshot.phase == .degraded, snapshot.degradedReason == .permissions else {
            return false
        }

        let permissions = await permissionCoordinator.checkAll()
        guard permissionsSatisfyRuntimeRequirements(permissions) else {
            return false
        }

        await lifecycle.setLastErrorCode(nil)
        try? await lifecycle.transition(to: .ready)
        await diagnostics.emit(
            DiagnosticEvent(
                name: "permissions_recovered",
                sessionID: nil,
                attributes: [
                    "microphone": permissions.microphone.rawValue,
                    "accessibility": permissions.accessibility.rawValue,
                    "inputMonitoring": permissions.inputMonitoring.rawValue
                ]
            )
        )
        await pushUI()
        return true
    }

    private func transcriptionFailureMessage(
        error: Error,
        settings: AppSettings,
        modelOverrides: TranscriptionModelOverrides
    ) -> String {
        let header = "Transcription failed."
        let nextSteps = """

Next steps:
- Check the selected provider keys and model names in Preferences -> Provider Setup.
- Try the fallback provider or switch the recording profile to a provider with a stored key.
- Run Checks from the menu bar after changing provider settings.
"""

        if case let TranscriptionPipelineError.retryAvailable(
            primary,
            fallback,
            primaryErrorDescription,
            fallbackErrorDescription
        ) = error {
            return """
            \(header)

            Primary: \(providerLabel(primary)) (\(modelLabel(for: primary, settings: settings, override: modelOverrides.primaryModel)))
            Reason: \(primaryErrorDescription)

            Fallback: \(providerLabel(fallback)) (\(modelLabel(for: fallback, settings: settings, override: modelOverrides.fallbackModel)))
            Reason: \(fallbackErrorDescription)
            \(nextSteps)
            """
        }

        if let pipelineError = error as? TranscriptionPipelineError {
            return "\(header)\n\nReason: \(pipelineError.diagnosticDescription)\(nextSteps)"
        }

        if let providerError = error as? ProviderError {
            return "\(header)\n\nReason: \(providerError.diagnosticDescription)\(nextSteps)"
        }

        return "\(header)\n\nReason: \(String(describing: error))\(nextSteps)"
    }

    private func workflowFailureMessage(stage: String, error: Error) -> String {
        if let audioError = error as? AudioCaptureError {
            switch audioError {
            case .callbackStalled:
                return """
                Microphone capture stopped unexpectedly.

                Quedo attempted automatic audio recovery but could not confirm new microphone frames. No audio is being recorded.

                Next steps:
                - The captured portion, if any, was preserved for retry.
                - Check the selected input device and run Checks from the menu bar.
                """
            case .noInputDevice:
                return "No microphone input device was available. No audio is being recorded."
            case .startTimedOut:
                return "Quedo could not start microphone capture within its safety timeout. No audio is being recorded."
            case .writerFailed:
                return "Quedo could not write microphone audio. No audio is being recorded."
            default:
                break
            }
        }

        return """
        \(stage.capitalized) failed.

        Reason: \(sanitizedDiagnostic(error))

        Next steps:
        - Retry the last recording from the menu bar.
        - If this repeats, run Checks from the menu bar and export diagnostics.
        """
    }

    private func preserveFailedCapture(
        _ capture: AudioCaptureResult,
        settings: AppSettings,
        createdAt: Date
    ) async -> AudioCaptureResult? {
        let pendingRecord = SessionRecord(
            sessionID: capture.sessionID,
            createdAt: createdAt,
            durationMS: capture.durationMS,
            providerPrimary: settings.provider.primary,
            providerUsed: settings.provider.primary,
            language: settings.language,
            outputMode: settings.outputMode,
            status: .retryAvailable,
            transcript: "",
            audioPath: capture.fileURL
        )

        do {
            let durableURL = try await historyStore.saveSession(pendingRecord)
            return AudioCaptureResult(
                sessionID: capture.sessionID,
                fileURL: durableURL,
                durationMS: capture.durationMS
            )
        } catch {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "partial_audio_history_save_failed",
                    sessionID: capture.sessionID,
                    attributes: diagnosticAttributes(for: error),
                    level: .error
                )
            )
            guard let recoveredURL = recoverAudioForManualImport(capture) else {
                return nil
            }
            return AudioCaptureResult(
                sessionID: capture.sessionID,
                fileURL: recoveredURL,
                durationMS: capture.durationMS
            )
        }
    }

    private func recoverAudioForManualImport(_ capture: AudioCaptureResult) -> URL? {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quedo", isDirectory: true)
        let recoveredDirectory = baseURL.appendingPathComponent("recovered", isDirectory: true)
        let recoveredURL = recoveredDirectory
            .appendingPathComponent("\(capture.sessionID.uuidString)-capture-recovery")
            .appendingPathExtension(capture.fileURL.pathExtension.isEmpty ? "wav" : capture.fileURL.pathExtension)

        do {
            try fileManager.createDirectory(at: recoveredDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: recoveredURL.path) {
                try fileManager.removeItem(at: recoveredURL)
            }
            try fileManager.copyItem(at: capture.fileURL, to: recoveredURL)
            return recoveredURL
        } catch {
            return nil
        }
    }

    private func errorCode(forFailureStage stage: String, error: Error? = nil) -> String {
        switch stage {
        case "audio capture":
            if let audioError = error as? AudioCaptureError {
                switch audioError {
                case .callbackStalled:
                    return "capture_recovery_failed"
                case .startTimedOut:
                    return "capture_start_timed_out"
                default:
                    break
                }
            }
            return "capture_open_failed"
        case "history pre-save", "history save":
            return "history_save_failed"
        case "output":
            return "output_failed"
        default:
            return "pipeline_failed"
        }
    }

    private func providerLabel(_ provider: ProviderKind) -> String {
        switch provider {
        case .groq:
            return "Groq"
        case .openAI:
            return "OpenAI"
        case .azureSpeech:
            return "Azure Speech"
        case .openRouter:
            return "OpenRouter"
        case .whisperCpp:
            return "whisper.cpp"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    private func modelLabel(for provider: ProviderKind, settings: AppSettings, override: String?) -> String {
        let value: String
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = override
        } else {
            switch provider {
            case .groq:
                value = settings.provider.groqModel
            case .openAI:
                value = settings.provider.openAIModel
            case .azureSpeech:
                value = settings.provider.azureSpeechModel
            case .openRouter:
                value = settings.provider.openRouterModel
            case .whisperCpp:
                value = settings.provider.whisperCppModelPath
            case .elevenLabs:
                value = settings.provider.elevenLabsModel
            }
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no model configured" : trimmed
    }

    private func sanitizedDiagnostic(_ error: Error) -> String {
        let raw: String
        if let pipelineError = error as? TranscriptionPipelineError {
            raw = pipelineError.diagnosticDescription
        } else if let providerError = error as? ProviderError {
            raw = providerError.diagnosticDescription
        } else {
            raw = String(describing: error)
        }
        return String(
            raw
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(800)
        )
    }

    private func messageForErrorCode(_ code: String) -> String {
        switch code {
        case "capture_open_failed":
            return "Audio capture failed to start. Check microphone access and selected input device."
        case "pipeline_failed":
            return "Transcription pipeline failed. Retry or switch provider."
        case "history_save_failed":
            return "Recording was captured, but Quedo could not save it to History."
        case "output_failed":
            return "Transcription succeeded, but Quedo could not copy or paste the output."
        case "permissions_not_ready":
            return "Required permissions are missing. Open System Settings and grant access."
        case "hotkey_registration_failed":
            return "Global hotkey registration failed. Try different hotkeys or re-run checks."
        case "provider_connectivity_failed":
            return "Both transcription providers failed connectivity checks."
        default:
            return "An unexpected runtime error occurred."
        }
    }

    private func messageForDegradedReason(_ reason: DegradedReason) -> String {
        switch reason {
        case .permissions:
            return "Permissions are missing for this app instance. Open System Settings and grant Microphone/Accessibility/Input Monitoring."
        case .noInputDevice:
            return "No input audio device was detected."
        case .providerUnavailable:
            return "No transcription provider is currently reachable."
        case .hotkeyFailure:
            return "Hotkey registration failed. Try another shortcut preset or manual mapping."
        case .internalError:
            return "The app entered degraded mode due to an internal error."
        }
    }
}
