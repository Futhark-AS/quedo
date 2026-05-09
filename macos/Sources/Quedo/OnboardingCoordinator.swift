import Foundation
import QuedoCore

/// Result of onboarding reliability gate execution.
struct OnboardingGateResult: Sendable {
    /// Indicates all required gates passed.
    let passed: Bool
    /// Degraded reason when gate fails.
    let degradedReason: DegradedReason
}

/// Handles first-run onboarding reliability checks.
actor OnboardingCoordinator {
    private enum Constants {
        static let completedKey = "quedo.onboarding.completed"
        static let legacyCompletedKey = "whisper.assistant.onboarding.completed"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func requiresOnboarding() async -> Bool {
        if userDefaults.bool(forKey: Constants.completedKey) {
            return false
        }
        if userDefaults.bool(forKey: Constants.legacyCompletedKey) {
            userDefaults.set(true, forKey: Constants.completedKey)
            return false
        }
        return true
    }

    func markCompleted() {
        userDefaults.set(true, forKey: Constants.completedKey)
        userDefaults.removeObject(forKey: Constants.legacyCompletedKey)
    }

    func runReliabilityGates(
        settings: AppSettings,
        hotkeyManager _: HotkeyManager,
        audioEngine: AudioCaptureEngine,
        pipeline: TranscriptionPipeline
    ) async -> OnboardingGateResult {
        let hotkeyPassed = runHotkeyVerification(settings: settings)
        if !hotkeyPassed {
            return OnboardingGateResult(passed: false, degradedReason: .hotkeyFailure)
        }

        let micPassed = await runMicrophoneLoopback(audioEngine: audioEngine)
        if !micPassed {
            return OnboardingGateResult(passed: false, degradedReason: .noInputDevice)
        }

        let connectivity = await pipeline.connectivityCheck(primary: settings.provider.primary, fallback: settings.provider.fallback)
        if !(connectivity.primaryOK || connectivity.fallbackOK) {
            return OnboardingGateResult(passed: false, degradedReason: .providerUnavailable)
        }

        if settings.outputMode == .none {
            return OnboardingGateResult(passed: false, degradedReason: .internalError)
        }

        markCompleted()
        return OnboardingGateResult(passed: true, degradedReason: .internalError)
    }

    private func runHotkeyVerification(settings: AppSettings) -> Bool {
        // Hotkeys are optional; if configured, at least one recording action must exist.
        if settings.hotkeys.isEmpty {
            return true
        }

        let configured = Set(settings.hotkeys.map(\.actionID))
        return configured.contains("toggle") || configured.contains(where: { $0.hasPrefix("recording.") })
    }

    private func runMicrophoneLoopback(audioEngine: AudioCaptureEngine) async -> Bool {
        let sessionID = UUID()
        do {
            try await audioEngine.startRecording(sessionID: sessionID)
            try? await Task.sleep(for: .seconds(2))
            let result = try await audioEngine.stopRecording()
            return result.durationMS >= 1800
        } catch {
            await audioEngine.cancelRecording()
            return false
        }
    }
}
