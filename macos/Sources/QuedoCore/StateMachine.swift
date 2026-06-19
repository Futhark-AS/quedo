import Foundation

/// Primary application lifecycle phase.
public enum AppPhase: String, Codable, Sendable {
    /// Bootstrapping services.
    case booting
    /// First-run setup flow.
    case onboarding
    /// Idle and ready for a new session.
    case ready
    /// Preparing audio capture.
    case arming
    /// Recording live audio.
    case recording
    /// Processing recorded audio.
    case processing
    /// Receiving partial transcription updates.
    case streamingPartial
    /// Attempting fallback provider after primary failure.
    case providerFallback
    /// Routing transcript output.
    case outputting
    /// Operation failed, retry is available.
    case retryAvailable
    /// Blocking runtime condition.
    case degraded
    /// Graceful shutdown in progress.
    case shuttingDown
}

/// Deterministic action names used by menu and UI surfaces.
public enum AppAction: String, Sendable, CaseIterable {
    /// Start a new recording session.
    case startRecording = "Start Recording"
    /// Cancel current workflow.
    case cancel = "Cancel"
    /// Stop current recording session.
    case stop = "Stop"
    /// Retry previously failed operation.
    case retry = "Retry"
    /// Open preferences window.
    case preferences = "Preferences"
    /// Open transcription history.
    case history = "History"
    /// Run diagnostic checks.
    case runChecks = "Run Checks"
    /// Copy partial transcript.
    case copyPartial = "Copy Partial"
    /// Open system settings.
    case openSettings = "Open Settings"
    /// Use clipboard-only output mode.
    case useClipboardOnly = "Use Clipboard Only"
    /// Refresh audio devices.
    case refreshDevices = "Refresh Devices"
    /// Select audio device.
    case selectDevice = "Select Device"
    /// Switch provider settings.
    case switchProvider = "Switch Provider"
    /// Open provider settings view.
    case openProviderSettings = "Open Provider Settings"
    /// Rebind the global hotkey.
    case rebindHotkey = "Rebind Hotkey"
    /// Retry hotkey registration.
    case retryRegistration = "Retry Registration"
    /// View diagnostics.
    case viewDiagnostics = "View Diagnostics"
    /// Force stop active capture.
    case forceStop = "Force Stop Recording"
    /// Export diagnostics bundle.
    case exportDiagnostics = "Export Diagnostics"
    /// Show most recent error details.
    case viewLastError = "View Last Error"
    /// Quit the application.
    case quit = "Quit"
}

/// Complete UI contract values for a phase snapshot.
public struct UIStateContract: Sendable {
    /// Symbolic icon name.
    public let icon: String
    /// Optional status copy.
    public let notificationCopy: String?
    /// Available actions.
    public let actions: [AppAction]

    /// Creates a UI contract value.
    public init(icon: String, notificationCopy: String?, actions: [AppAction]) {
        self.icon = icon
        self.notificationCopy = notificationCopy
        self.actions = actions
    }
}

/// Immutable lifecycle snapshot consumed by UI and diagnostics.
public struct AppLifecycleSnapshot: Sendable {
    /// Current primary lifecycle phase.
    public let phase: AppPhase
    /// Optional degraded reason.
    public let degradedReason: DegradedReason?
    /// Active session identifier.
    public let currentSessionID: UUID?
    /// Indicates whether fallback has been attempted for the active session.
    public let fallbackAttempted: Bool
    /// Most recent diagnostic error code.
    public let lastErrorCode: String?

    /// Creates a lifecycle snapshot.
    public init(
        phase: AppPhase,
        degradedReason: DegradedReason?,
        currentSessionID: UUID?,
        fallbackAttempted: Bool,
        lastErrorCode: String?
    ) {
        self.phase = phase
        self.degradedReason = degradedReason
        self.currentSessionID = currentSessionID
        self.fallbackAttempted = fallbackAttempted
        self.lastErrorCode = lastErrorCode
    }
}

/// Structured state machine transition error.
public struct StateTransitionError: Error, Sendable {
    /// Source phase.
    public let from: AppPhase
    /// Target phase.
    public let to: AppPhase
    /// Transition rejection reason.
    public let reason: String

    /// Creates a transition error.
    public init(from: AppPhase, to: AppPhase, reason: String) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// Event emitted for every accepted state transition.
public struct LifecycleTransitionEvent: Sendable {
    /// Transition source.
    public let from: AppPhase
    /// Transition target.
    public let to: AppPhase
    /// Transition timestamp.
    public let timestamp: Date

    /// Creates a transition event.
    public init(from: AppPhase, to: AppPhase, timestamp: Date = Date()) {
        self.from = from
        self.to = to
        self.timestamp = timestamp
    }
}

/// Single authoritative lifecycle state machine.
public actor LifecycleStateMachine {
    private var phase: AppPhase = .booting
    private var degradedReason: DegradedReason?
    private var currentSessionID: UUID?
    private var fallbackAttempted = false
    private var lastErrorCode: String?
    private let onTransition: @Sendable (LifecycleTransitionEvent) -> Void

    /// Creates a state machine with optional diagnostics callback.
    public init(onTransition: @escaping @Sendable (LifecycleTransitionEvent) -> Void = { _ in }) {
        self.onTransition = onTransition
    }

    /// Returns current lifecycle snapshot.
    public func snapshot() -> AppLifecycleSnapshot {
        AppLifecycleSnapshot(
            phase: phase,
            degradedReason: degradedReason,
            currentSessionID: currentSessionID,
            fallbackAttempted: fallbackAttempted,
            lastErrorCode: lastErrorCode
        )
    }

    /// Resets runtime derived state for a new session.
    public func beginSession(id: UUID) throws {
        guard currentSessionID == nil else {
            throw StateTransitionError(from: phase, to: phase, reason: "Only one active session is allowed")
        }

        currentSessionID = id
        fallbackAttempted = false
        lastErrorCode = nil
    }

    /// Ends the active session and clears derived session values.
    public func endSession() {
        currentSessionID = nil
        fallbackAttempted = false
    }

    /// Marks that provider fallback was attempted for this session.
    public func markFallbackAttempted() {
        fallbackAttempted = true
    }

    /// Sets the most recent error code.
    public func setLastErrorCode(_ value: String?) {
        lastErrorCode = value
    }

    /// Sets degraded reason while in degraded phase.
    public func setDegradedReason(_ value: DegradedReason?) {
        degradedReason = value
    }

    /// Transitions to a new phase with deterministic guard checks.
    public func transition(to next: AppPhase, degradedReason nextReason: DegradedReason? = nil) throws {
        if phase == next {
            return
        }
        guard isAllowedTransition(from: phase, to: next) else {
            throw StateTransitionError(from: phase, to: next, reason: "Transition is not permitted")
        }

        let from = phase
        phase = next

        if next == .degraded {
            degradedReason = nextReason ?? .internalError
        } else if next == .ready {
            degradedReason = nil
        }

        onTransition(LifecycleTransitionEvent(from: from, to: next))
    }

    /// Returns UI contract for the current phase snapshot.
    public func uiContract() -> UIStateContract {
        Self.uiContract(for: phase, degradedReason: degradedReason)
    }

    /// Returns UI contract for any provided phase and degraded reason.
    public static func uiContract(for phase: AppPhase, degradedReason: DegradedReason?) -> UIStateContract {
        switch phase {
        case .ready:
            return UIStateContract(
                icon: "mic",
                notificationCopy: nil,
                actions: [.startRecording, .preferences, .history, .runChecks]
            )
        case .arming:
            return UIStateContract(
                icon: "mic.circle.badge.clock",
                notificationCopy: "Preparing microphone...",
                actions: [.cancel]
            )
        case .recording:
            return UIStateContract(
                icon: "record.circle.fill",
                notificationCopy: "Recording. Press shortcut to stop.",
                actions: [.stop, .cancel]
            )
        case .processing:
            return UIStateContract(
                icon: "waveform",
                notificationCopy: "Processing audio...",
                actions: [.cancel]
            )
        case .streamingPartial:
            return UIStateContract(
                icon: "waveform.badge.plus",
                notificationCopy: "Transcribing (live)...",
                actions: [.cancel, .copyPartial]
            )
        case .providerFallback:
            return UIStateContract(
                icon: "arrow.triangle.2.circlepath",
                notificationCopy: "Primary provider unavailable. Trying fallback...",
                actions: [.cancel]
            )
        case .outputting:
            return UIStateContract(
                icon: "doc.on.clipboard",
                notificationCopy: "Sending transcript...",
                actions: []
            )
        case .retryAvailable:
            return UIStateContract(
                icon: "arrow.clockwise",
                notificationCopy: "Could not complete. Retry is available.",
                actions: [.retry, .switchProvider, .viewDiagnostics]
            )
        case .degraded:
            let reason = degradedReason ?? .internalError
            switch reason {
            case .permissions:
                return UIStateContract(
                    icon: "shield",
                    notificationCopy: "Permission needed for full functionality.",
                    actions: [.openSettings, .runChecks, .useClipboardOnly]
                )
            case .noInputDevice:
                return UIStateContract(
                    icon: "mic.slash",
                    notificationCopy: "No input device detected.",
                    actions: [.refreshDevices, .selectDevice, .runChecks]
                )
            case .providerUnavailable:
                return UIStateContract(
                    icon: "icloud.slash",
                    notificationCopy: "Transcription provider unavailable.",
                    actions: [.retry, .switchProvider, .openProviderSettings]
                )
            case .hotkeyFailure:
                return UIStateContract(
                    icon: "keyboard",
                    notificationCopy: "Hotkey registration failed.",
                    actions: [.rebindHotkey, .retryRegistration]
                )
            case .internalError:
                return UIStateContract(
                    icon: "exclamationmark.triangle",
                    notificationCopy: "Unexpected runtime issue.",
                    actions: [.viewDiagnostics, .runChecks]
                )
            }
        case .shuttingDown:
            return UIStateContract(icon: "circle", notificationCopy: nil, actions: [.quit])
        case .booting, .onboarding:
            return UIStateContract(icon: "hourglass", notificationCopy: nil, actions: [])
        }
    }

    private func isAllowedTransition(from current: AppPhase, to next: AppPhase) -> Bool {
        if next == .degraded {
            return true
        }

        switch (current, next) {
        case (.booting, .onboarding), (.booting, .ready):
            return true
        case (.onboarding, .ready):
            return true
        case (.ready, .arming):
            return currentSessionID != nil
        case (.arming, .recording):
            return true
        case (.arming, .degraded):
            return true
        case (.arming, .ready):
            return true
        case (.recording, .processing):
            return true
        case (.recording, .ready):
            return true
        case (.processing, .streamingPartial), (.processing, .outputting), (.processing, .providerFallback):
            return true
        case (.processing, .retryAvailable):
            return true
        case (.processing, .ready):
            return true
        case (.streamingPartial, .outputting), (.streamingPartial, .providerFallback):
            return true
        case (.streamingPartial, .ready):
            return true
        case (.providerFallback, .outputting), (.providerFallback, .retryAvailable):
            return true
        case (.providerFallback, .ready):
            return true
        case (.outputting, .ready), (.outputting, .retryAvailable):
            return true
        case (.retryAvailable, .processing):
            return true
        case (.retryAvailable, .ready):
            return true
        case (.degraded, .ready):
            return true
        case (_, .shuttingDown):
            return true
        default:
            return false
        }
    }
}
