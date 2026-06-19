import Foundation
import QuedoCore

/// Application coordinator actor and single lifecycle owner.
actor AppControllerActor {
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
    private var activeRecordingProfile: RecordingShortcutProfile?
    private var latestErrorDetail: String?

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
        do {
            settings = try await configurationManager.loadSettings()
            try await applyHotkeyBindings()

            await audioEngine.prepareEngine()
            let permissionSnapshot = await permissionCoordinator.checkAll()

            if !permissionsSatisfyRuntimeRequirements(permissionSnapshot) {
                try await lifecycle.transition(to: .degraded, degradedReason: .permissions)
                await diagnostics.emit(
                    DiagnosticEvent(name: "degraded_enter_total", sessionID: nil, attributes: ["reason": "permissions"])
                )
                await pushUI()
                return
            }

            if await onboardingCoordinator.requiresOnboarding() {
                try await lifecycle.transition(to: .onboarding)
                await pushUI()
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
                await pushUI()
                return
            }

            try await lifecycle.transition(to: .ready)
            await pushUI()
        } catch {
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "degraded_enter_total",
                    sessionID: nil,
                    attributes: ["reason": "internalError", "error": String(describing: error)]
                )
            )
            do {
                try await lifecycle.transition(to: .degraded, degradedReason: .internalError)
            } catch {
                // Keep current phase if transition fails.
            }
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
                    attributes: ["error": String(describing: error)]
                )
            )
        }
    }

    func handleMenuAction(_ action: AppAction) async {
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
                    DiagnosticEvent(name: "settings_save_error", sessionID: nil, attributes: ["error": String(describing: error)])
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
        if event == .pressed {
            await diagnostics.recordMetric(
                MetricPoint(name: "hotkey_trigger_total", value: 1, tags: ["action": actionID])
            )
        }
        let snapshot = await lifecycle.snapshot()

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
        await audioEngine.cancelRecording()
        hotkeyManager.deactivate()
        await transcriptionPipeline.shutdown()
        try? await lifecycle.transition(to: .shuttingDown)
        await pushUI()
    }

    func refreshPermissionStateAfterActivation() async {
        _ = await recoverFromPermissionDegradedStateIfPossible()
    }

    private func startRecordingFlow(profile: RecordingShortcutProfile? = nil) async {
        if isRecording {
            return
        }
        let snapshot = await lifecycle.snapshot()
        guard snapshot.currentSessionID == nil else {
            return
        }

        let sessionID = UUID()
        do {
            latestErrorDetail = nil
            activeRecordingProfile = profile
            try await lifecycle.beginSession(id: sessionID)
            try await lifecycle.transition(to: .arming)
            await pushUI()

            try await audioEngine.startRecording(sessionID: sessionID)
            let armed = await audioEngine.waitForFirstFrame(timeout: .seconds(2))
            guard armed else {
                let postArmSnapshot = await lifecycle.snapshot()
                if postArmSnapshot.currentSessionID == nil || postArmSnapshot.phase == .ready {
                    return
                }
                throw AudioCaptureError.streamOpenFailed
            }

            try await lifecycle.transition(to: .recording)
            isRecording = true
            await diagnostics.recordMetric(MetricPoint(name: "session_start_total", value: 1, tags: [:]))
            await pushUI()
        } catch let error as AudioCaptureError {
            await audioEngine.cancelRecording()
            isRecording = false
            activeRecordingProfile = nil
            let degraded: DegradedReason = (error == .noInputDevice) ? .noInputDevice : .internalError
            try? await lifecycle.transition(to: .degraded, degradedReason: degraded)
            await lifecycle.setLastErrorCode("capture_open_failed")
            await diagnostics.recordMetric(
                MetricPoint(name: "session_start_failed_total", value: 1, tags: ["reason": "capture_open_failed"])
            )
            await pushUI()
            await lifecycle.endSession()
        } catch {
            await audioEngine.cancelRecording()
            isRecording = false
            activeRecordingProfile = nil
            try? await lifecycle.transition(to: .degraded, degradedReason: .internalError)
            await pushUI()
            await lifecycle.endSession()
        }
    }

    private func stopRecordingFlow() async {
        guard isRecording else {
            return
        }

        var failureStage = "audio capture"
        do {
            try await lifecycle.transition(to: .processing)
            await pushUI()

            let capture = try await audioEngine.stopRecording()
            latestAudio = capture
            isRecording = false

            let start = Date()
            let transcriptionSettings = settingsForActiveRecordingProfile()
            failureStage = "transcription"
            let pipelineResult = try await transcriptionPipeline.transcribe(
                audioFileURL: capture.fileURL,
                settings: transcriptionSettings,
                modelOverrides: modelOverridesForActiveRecordingProfile()
            )

            if pipelineResult.fallbackUsed {
                try? await lifecycle.transition(to: .providerFallback)
                await pushUI()
                await lifecycle.markFallbackAttempted()
            }

            try await lifecycle.transition(to: .outputting)
            await pushUI()

            failureStage = "output"
            _ = try await outputRouter.route(text: pipelineResult.text, mode: settings.outputMode, profile: settings.buildProfile)

            let sessionID = capture.sessionID
            let record = SessionRecord(
                sessionID: sessionID,
                createdAt: Date(),
                durationMS: capture.durationMS,
                providerPrimary: transcriptionSettings.provider.primary,
                providerUsed: pipelineResult.providerUsed,
                language: transcriptionSettings.language,
                outputMode: settings.outputMode,
                status: .success,
                transcript: pipelineResult.text,
                audioPath: capture.fileURL
            )

            failureStage = "history save"
            try await historyStore.saveSession(record)
            await diagnostics.recordMetric(
                MetricPoint(
                    name: "session_latency_stop_to_final_transcript_ms",
                    value: Date().timeIntervalSince(start) * 1000,
                    tags: [:]
                )
            )

            try await lifecycle.transition(to: .ready)
            await lifecycle.endSession()
            activeRecordingProfile = nil
            latestErrorDetail = nil
            await pushUI()
        } catch {
            isRecording = false
            let failedSettings = settingsForActiveRecordingProfile()
            let failedOverrides = modelOverridesForActiveRecordingProfile()
            let detail: String
            if failureStage == "transcription" {
                detail = transcriptionFailureMessage(error: error, settings: failedSettings, modelOverrides: failedOverrides)
            } else {
                detail = workflowFailureMessage(stage: failureStage, error: error)
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
            activeRecordingProfile = nil
            try? await lifecycle.transition(to: .retryAvailable)
            await lifecycle.setLastErrorCode("pipeline_failed")
            await lifecycle.endSession()
            await pushUI()
        }
    }

    private func retryFlow() async {
        guard let latestAudio else {
            return
        }

        do {
            try await lifecycle.transition(to: .processing)
            await pushUI()

            let result = try await transcriptionPipeline.transcribe(audioFileURL: latestAudio.fileURL, settings: settings)
            try await lifecycle.transition(to: .outputting)
            await pushUI()

            _ = try await outputRouter.route(text: result.text, mode: settings.outputMode, profile: settings.buildProfile)

            try await lifecycle.transition(to: .ready)
            await lifecycle.endSession()
            latestErrorDetail = nil
            await pushUI()
        } catch {
            latestErrorDetail = transcriptionFailureMessage(
                error: error,
                settings: settings,
                modelOverrides: TranscriptionModelOverrides()
            )
            await diagnostics.emit(
                DiagnosticEvent(
                    name: "transcription_retry_failed",
                    sessionID: latestAudio.sessionID,
                    attributes: [
                        "primary": settings.provider.primary.rawValue,
                        "fallback": settings.provider.fallback.rawValue,
                        "error": sanitizedDiagnostic(error)
                    ]
                )
            )
            try? await lifecycle.transition(to: .retryAvailable)
            await lifecycle.setLastErrorCode("pipeline_failed")
            await lifecycle.endSession()
            await pushUI()
        }
    }

    private func cancelFlow() async {
        await audioEngine.cancelRecording()
        isRecording = false
        activeRecordingProfile = nil
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
                    attributes: ["error": String(describing: error)]
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
                    attributes: ["error": String(describing: error)]
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
                    attributes: ["error": String(describing: error)]
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
        """
        \(stage.capitalized) failed.

        Reason: \(sanitizedDiagnostic(error))

        Next steps:
        - Retry the last recording from the menu bar.
        - If this repeats, run Checks from the menu bar and export diagnostics.
        """
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
