import Foundation

/// Distribution profile that controls feature availability.
public enum BuildProfile: String, Codable, Sendable {
    /// Direct Developer ID distribution.
    case direct
    /// Mac App Store distribution.
    case mas
}

/// Output destination mode for finalized transcripts.
public enum OutputMode: String, Codable, Sendable, CaseIterable {
    /// Do not emit output.
    case none
    /// Copy transcript to clipboard only.
    case clipboard
    /// Paste transcript at the current cursor location.
    case pasteAtCursor
    /// Copy and paste transcript.
    case clipboardAndPaste
}

public extension OutputMode {
    /// Returns true when this output mode requires Accessibility permission.
    func requiresAccessibilityPermission(buildProfile: BuildProfile) -> Bool {
        switch self {
        case .none, .clipboard:
            return false
        case .pasteAtCursor, .clipboardAndPaste:
            return buildProfile == .direct
        }
    }
}

/// Available provider families for transcription.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// Groq hosted model endpoints.
    case groq
    /// OpenAI hosted model endpoints.
    case openAI
    /// Local whisper.cpp CLI backend.
    case whisperCpp
    /// ElevenLabs hosted Speech to Text endpoints.
    case elevenLabs
}

/// Runtime mode for the local whisper.cpp provider.
public enum WhisperCppRuntime: String, Codable, Sendable, CaseIterable {
    /// Prefer server when available, otherwise fallback to CLI.
    case auto
    /// Force persistent local whisper-server.
    case server
    /// Force per-request whisper-cli invocation.
    case cli
}

/// Mode for handling recording with hotkeys.
public enum RecordingInteractionMode: String, Codable, Sendable, CaseIterable {
    /// Press once to start and once to stop.
    case toggle
    /// Hold key to record while pressed.
    case hold
}

/// Edge phase for a global hotkey event.
public enum HotkeyEvent: String, Sendable {
    /// Shortcut became active.
    case pressed
    /// Shortcut became inactive.
    case released
}

/// Recording command derived from a toggle action hotkey event.
public enum ToggleHotkeyCommand: String, Sendable, Equatable {
    /// No-op for current state.
    case none
    /// Start a new recording session.
    case start
    /// Stop active recording and process output.
    case stop
    /// Cancel arming when recording has not begun yet.
    case cancelArming
}

/// Decision helper for routing toggle hotkey actions in toggle/hold interaction modes.
public enum HotkeyRouting {
    /// Computes the command for a toggle hotkey event and current lifecycle state.
    public static func toggleCommand(
        mode: RecordingInteractionMode,
        event: HotkeyEvent,
        phase: AppPhase,
        isRecording: Bool,
        hasActiveSession: Bool
    ) -> ToggleHotkeyCommand {
        switch mode {
        case .toggle:
            guard event == .pressed else {
                return .none
            }
            if phase == .arming {
                return .cancelArming
            }
            if isRecording {
                return .stop
            }
            if !hasActiveSession, phase == .ready {
                return .start
            }
            return .none
        case .hold:
            switch event {
            case .pressed:
                if !isRecording, !hasActiveSession, phase == .ready {
                    return .start
                }
                return .none
            case .released:
                if phase == .arming {
                    return .cancelArming
                }
                if isRecording {
                    return .stop
                }
                return .none
            }
        }
    }
}

/// Supported hotkey modifiers.
public struct HotkeyModifiers: OptionSet, Codable, Sendable, Hashable {
    /// Raw bitmask value.
    public let rawValue: UInt32

    /// Creates a modifier bitmask.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Command key.
    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    /// Option/alt key.
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    /// Control key.
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    /// Shift key.
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)
    /// Function (Fn) key.
    public static let function = HotkeyModifiers(rawValue: 1 << 4)
}

/// A concrete hotkey binding.
public struct HotkeyBinding: Codable, Hashable, Sendable {
    /// Stable action identifier.
    public let actionID: String
    /// macOS virtual key code.
    public let keyCode: UInt32
    /// Required key modifiers.
    public let modifiers: HotkeyModifiers

    /// Creates a new hotkey binding.
    public init(actionID: String, keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.actionID = actionID
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public extension HotkeyBinding {
    /// Sentinel key code representing a modifier-only chord.
    static let modifiersOnlyKeyCode: UInt32 = UInt32.max
}

/// Per-shortcut transcription settings for starting a recording.
public struct RecordingShortcutProfile: Codable, Hashable, Sendable, Identifiable {
    /// Stable profile identifier.
    public var id: String
    /// Display name shown in preferences.
    public var name: String
    /// Hotkey binding that starts/stops this profile.
    public var hotkey: HotkeyBinding
    /// Provider to use for recordings started by this hotkey.
    public var provider: ProviderKind
    /// Fallback provider for recordings started by this hotkey.
    public var fallbackProvider: ProviderKind
    /// Model identifier for the selected provider.
    public var model: String
    /// Model identifier for the fallback provider.
    public var fallbackModel: String
    /// Language code or `auto` for this hotkey.
    public var language: String

    /// Action id used in the hotkey manager.
    public var actionID: String {
        "recording.\(id)"
    }

    /// Creates a recording shortcut profile.
    public init(
        id: String,
        name: String,
        hotkey: HotkeyBinding,
        provider: ProviderKind,
        fallbackProvider: ProviderKind = ProviderConfiguration.defaultValue.fallback,
        model: String,
        fallbackModel: String? = nil,
        language: String
    ) {
        self.id = id
        self.name = name
        self.hotkey = hotkey
        self.provider = provider
        self.fallbackProvider = fallbackProvider
        self.model = model
        self.fallbackModel = fallbackModel ?? RecordingShortcutProfile.defaultModel(for: fallbackProvider)
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case hotkey
        case provider
        case fallbackProvider
        case model
        case fallbackModel
        case language
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hotkey = try container.decode(HotkeyBinding.self, forKey: .hotkey)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        fallbackProvider = try container.decodeIfPresent(ProviderKind.self, forKey: .fallbackProvider) ?? RecordingShortcutProfile.defaultFallback(excluding: provider)
        model = try container.decode(String.self, forKey: .model)
        fallbackModel = try container.decodeIfPresent(String.self, forKey: .fallbackModel) ?? RecordingShortcutProfile.defaultModel(for: fallbackProvider)
        language = try container.decode(String.self, forKey: .language)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(provider, forKey: .provider)
        try container.encode(fallbackProvider, forKey: .fallbackProvider)
        try container.encode(model, forKey: .model)
        try container.encode(fallbackModel, forKey: .fallbackModel)
        try container.encode(language, forKey: .language)
    }
}

public extension RecordingShortcutProfile {
    /// Returns a fallback provider that differs from the requested provider.
    static func defaultFallback(excluding provider: ProviderKind) -> ProviderKind {
        if ProviderConfiguration.defaultValue.fallback != provider {
            return ProviderConfiguration.defaultValue.fallback
        }
        return ProviderKind.allCases.first { $0 != provider } ?? .groq
    }

    /// Returns the configured default model for a provider.
    static func defaultModel(for provider: ProviderKind) -> String {
        switch provider {
        case .groq:
            return ProviderConfiguration.defaultValue.groqModel
        case .openAI:
            return ProviderConfiguration.defaultValue.openAIModel
        case .whisperCpp:
            return ProviderConfiguration.defaultValue.whisperCppModelPath
        case .elevenLabs:
            return ProviderConfiguration.defaultValue.elevenLabsModel
        }
    }

    /// Default recording profile matching the historical toggle shortcut.
    static let defaultProfile = RecordingShortcutProfile(
        id: "default",
        name: "Default",
        hotkey: HotkeyBinding(actionID: "recording.default", keyCode: HotkeyBinding.modifiersOnlyKeyCode, modifiers: [.control, .function]),
        provider: .groq,
        fallbackProvider: .openAI,
        model: ProviderConfiguration.defaultValue.groqModel,
        fallbackModel: ProviderConfiguration.defaultValue.openAIModel,
        language: "auto"
    )
}

/// Provider credentials and request-time settings.
public struct ProviderConfiguration: Codable, Sendable {
    /// Primary provider to use for normal operations.
    public var primary: ProviderKind
    /// Fallback provider used when primary is unavailable.
    public var fallback: ProviderKind
    /// Groq API key secret identifier.
    public var groqAPIKeyRef: String
    /// OpenAI API key secret identifier.
    public var openAIAPIKeyRef: String
    /// ElevenLabs API key secret identifier.
    public var elevenLabsAPIKeyRef: String
    /// Request timeout for short clips in seconds.
    public var timeoutSeconds: Int
    /// Selected model identifier for Groq.
    public var groqModel: String
    /// Selected model identifier for OpenAI.
    public var openAIModel: String
    /// whisper.cpp model path or model filename.
    public var whisperCppModelPath: String
    /// whisper.cpp runtime mode.
    public var whisperCppRuntime: WhisperCppRuntime
    /// Selected model identifier for ElevenLabs Speech to Text.
    public var elevenLabsModel: String

    /// Baseline defaults for provider configuration.
    public static let defaultValue = ProviderConfiguration(
        primary: .groq,
        fallback: .openAI,
        groqAPIKeyRef: "groq_api_key",
        openAIAPIKeyRef: "openai_api_key",
        elevenLabsAPIKeyRef: "elevenlabs_api_key",
        timeoutSeconds: 12,
        groqModel: "whisper-large-v3",
        openAIModel: "gpt-4o-mini-transcribe",
        whisperCppModelPath: "ggml-large-v3.bin",
        whisperCppRuntime: .auto,
        elevenLabsModel: "scribe_v2"
    )

    /// Creates provider configuration values.
    public init(
        primary: ProviderKind,
        fallback: ProviderKind,
        groqAPIKeyRef: String,
        openAIAPIKeyRef: String,
        elevenLabsAPIKeyRef: String = ProviderConfiguration.defaultValue.elevenLabsAPIKeyRef,
        timeoutSeconds: Int,
        groqModel: String,
        openAIModel: String,
        whisperCppModelPath: String,
        whisperCppRuntime: WhisperCppRuntime,
        elevenLabsModel: String = ProviderConfiguration.defaultValue.elevenLabsModel
    ) {
        self.primary = primary
        self.fallback = fallback
        self.groqAPIKeyRef = groqAPIKeyRef
        self.openAIAPIKeyRef = openAIAPIKeyRef
        self.elevenLabsAPIKeyRef = elevenLabsAPIKeyRef
        self.timeoutSeconds = timeoutSeconds
        self.groqModel = groqModel
        self.openAIModel = openAIModel
        self.whisperCppModelPath = whisperCppModelPath
        self.whisperCppRuntime = whisperCppRuntime
        self.elevenLabsModel = elevenLabsModel
    }

    private enum CodingKeys: String, CodingKey {
        case primary
        case fallback
        case groqAPIKeyRef
        case openAIAPIKeyRef
        case elevenLabsAPIKeyRef
        case timeoutSeconds
        case groqModel
        case openAIModel
        case whisperCppModelPath
        case whisperCppRuntime
        case elevenLabsModel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProviderConfiguration.defaultValue

        primary = try container.decodeIfPresent(ProviderKind.self, forKey: .primary) ?? defaults.primary
        fallback = try container.decodeIfPresent(ProviderKind.self, forKey: .fallback) ?? defaults.fallback
        groqAPIKeyRef = try container.decodeIfPresent(String.self, forKey: .groqAPIKeyRef) ?? defaults.groqAPIKeyRef
        openAIAPIKeyRef = try container.decodeIfPresent(String.self, forKey: .openAIAPIKeyRef) ?? defaults.openAIAPIKeyRef
        elevenLabsAPIKeyRef = try container.decodeIfPresent(String.self, forKey: .elevenLabsAPIKeyRef) ?? defaults.elevenLabsAPIKeyRef
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        groqModel = try container.decodeIfPresent(String.self, forKey: .groqModel) ?? defaults.groqModel
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? defaults.openAIModel
        whisperCppModelPath = try container.decodeIfPresent(String.self, forKey: .whisperCppModelPath) ?? defaults.whisperCppModelPath
        whisperCppRuntime = try container.decodeIfPresent(WhisperCppRuntime.self, forKey: .whisperCppRuntime) ?? defaults.whisperCppRuntime
        elevenLabsModel = try container.decodeIfPresent(String.self, forKey: .elevenLabsModel) ?? defaults.elevenLabsModel
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(primary, forKey: .primary)
        try container.encode(fallback, forKey: .fallback)
        try container.encode(groqAPIKeyRef, forKey: .groqAPIKeyRef)
        try container.encode(openAIAPIKeyRef, forKey: .openAIAPIKeyRef)
        try container.encode(elevenLabsAPIKeyRef, forKey: .elevenLabsAPIKeyRef)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(groqModel, forKey: .groqModel)
        try container.encode(openAIModel, forKey: .openAIModel)
        try container.encode(whisperCppModelPath, forKey: .whisperCppModelPath)
        try container.encode(whisperCppRuntime, forKey: .whisperCppRuntime)
        try container.encode(elevenLabsModel, forKey: .elevenLabsModel)
    }
}

/// Persisted application preferences.
public struct AppSettings: Codable, Sendable {
    /// Active distribution profile.
    public var buildProfile: BuildProfile
    /// Transcript output mode.
    public var outputMode: OutputMode
    /// Language code or `auto`.
    public var language: String
    /// Extra vocabulary hints.
    public var vocabularyHints: [String]
    /// Primary interaction mode.
    public var recordingInteraction: RecordingInteractionMode
    /// Whether app should register for launch at login.
    public var launchAtLoginEnabled: Bool
    /// Declared hotkey mappings.
    public var hotkeys: [HotkeyBinding]
    /// Recording hotkeys with provider/model/language overrides.
    public var recordingProfiles: [RecordingShortcutProfile]
    /// Provider-specific settings.
    public var provider: ProviderConfiguration

    /// Creates settings data.
    public init(
        buildProfile: BuildProfile,
        outputMode: OutputMode,
        language: String,
        vocabularyHints: [String],
        recordingInteraction: RecordingInteractionMode,
        launchAtLoginEnabled: Bool,
        hotkeys: [HotkeyBinding],
        recordingProfiles: [RecordingShortcutProfile] = [RecordingShortcutProfile.defaultProfile],
        provider: ProviderConfiguration
    ) {
        self.buildProfile = buildProfile
        self.outputMode = outputMode
        self.language = language
        self.vocabularyHints = vocabularyHints
        self.recordingInteraction = recordingInteraction
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.hotkeys = hotkeys
        self.recordingProfiles = recordingProfiles
        self.provider = provider
    }

    /// Baseline defaults used for first launch.
    public static let `default` = AppSettings(
        buildProfile: .direct,
        outputMode: .clipboardAndPaste,
        language: "auto",
        vocabularyHints: [],
        recordingInteraction: .toggle,
        launchAtLoginEnabled: true,
        hotkeys: [
            RecordingShortcutProfile.defaultProfile.hotkey,
            HotkeyBinding(actionID: "retry", keyCode: 15, modifiers: [.control, .function]),
            HotkeyBinding(actionID: "cancel", keyCode: 53, modifiers: [.control, .function])
        ],
        recordingProfiles: [RecordingShortcutProfile.defaultProfile],
        provider: .defaultValue
    )

    private enum CodingKeys: String, CodingKey {
        case buildProfile
        case outputMode
        case language
        case vocabularyHints
        case recordingInteraction
        case launchAtLoginEnabled
        case hotkeys
        case recordingProfiles
        case provider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.default

        buildProfile = try container.decodeIfPresent(BuildProfile.self, forKey: .buildProfile) ?? defaults.buildProfile
        outputMode = try container.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? defaults.outputMode
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
        vocabularyHints = try container.decodeIfPresent([String].self, forKey: .vocabularyHints) ?? defaults.vocabularyHints
        recordingInteraction = try container.decodeIfPresent(RecordingInteractionMode.self, forKey: .recordingInteraction) ?? defaults.recordingInteraction
        launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? defaults.launchAtLoginEnabled
        hotkeys = try container.decodeIfPresent([HotkeyBinding].self, forKey: .hotkeys) ?? defaults.hotkeys
        provider = try container.decodeIfPresent(ProviderConfiguration.self, forKey: .provider) ?? defaults.provider
        recordingProfiles = try container.decodeIfPresent([RecordingShortcutProfile].self, forKey: .recordingProfiles)
            ?? AppSettings.defaultRecordingProfiles(from: hotkeys, provider: provider, language: language)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(buildProfile, forKey: .buildProfile)
        try container.encode(outputMode, forKey: .outputMode)
        try container.encode(language, forKey: .language)
        try container.encode(vocabularyHints, forKey: .vocabularyHints)
        try container.encode(recordingInteraction, forKey: .recordingInteraction)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(hotkeys, forKey: .hotkeys)
        try container.encode(recordingProfiles, forKey: .recordingProfiles)
        try container.encode(provider, forKey: .provider)
    }

    private static func defaultRecordingProfiles(
        from hotkeys: [HotkeyBinding],
        provider: ProviderConfiguration,
        language: String
    ) -> [RecordingShortcutProfile] {
        let legacyToggle = hotkeys.first { $0.actionID == "toggle" } ?? RecordingShortcutProfile.defaultProfile.hotkey
        let hotkey = HotkeyBinding(actionID: "recording.default", keyCode: legacyToggle.keyCode, modifiers: legacyToggle.modifiers)
        return [
            RecordingShortcutProfile(
                id: "default",
                name: "Default",
                hotkey: hotkey,
                provider: provider.primary,
                fallbackProvider: provider.fallback,
                model: defaultModel(for: provider.primary, provider: provider),
                fallbackModel: defaultModel(for: provider.fallback, provider: provider),
                language: language
            )
        ]
    }

    private static func defaultModel(for kind: ProviderKind, provider: ProviderConfiguration) -> String {
        switch kind {
        case .groq:
            return provider.groqModel
        case .openAI:
            return provider.openAIModel
        case .whisperCpp:
            return provider.whisperCppModelPath
        case .elevenLabs:
            return provider.elevenLabsModel
        }
    }
}

/// A single settings validation error.
public struct SettingsValidationIssue: Error, Equatable, Sendable {
    /// Invalid field path.
    public let field: String
    /// Human-readable reason.
    public let message: String

    /// Creates a validation issue.
    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

/// Aggregated validation error container matching Python parity behavior.
public struct SettingsValidationErrorSet: Error, Sendable {
    /// All validation issues found in one pass.
    public let issues: [SettingsValidationIssue]

    /// Creates a grouped validation error.
    public init(issues: [SettingsValidationIssue]) {
        self.issues = issues
    }
}

/// Lifecycle-level degraded reasons.
public enum DegradedReason: String, Codable, Sendable {
    /// Missing required permissions.
    case permissions
    /// No active input device is available.
    case noInputDevice
    /// Provider health prevents transcription.
    case providerUnavailable
    /// Hotkey registration or dispatch failed.
    case hotkeyFailure
    /// Internal unexpected condition.
    case internalError
}

/// Session-level status used by history persistence.
public enum SessionStatus: String, Codable, Sendable {
    /// Session completed successfully.
    case success
    /// Session failed and can be retried.
    case retryAvailable
    /// Session was cancelled.
    case cancelled
    /// Session failed terminally.
    case failed
}

/// Captured session metadata and transcript output.
public struct SessionRecord: Sendable {
    /// Stable session UUID.
    public let sessionID: UUID
    /// Session creation timestamp.
    public let createdAt: Date
    /// Recorded audio duration in milliseconds.
    public let durationMS: Int
    /// Configured primary provider.
    public let providerPrimary: ProviderKind
    /// Provider used to generate final output.
    public let providerUsed: ProviderKind
    /// Language used for transcription.
    public let language: String
    /// Output mode used for routing.
    public let outputMode: OutputMode
    /// Final status.
    public let status: SessionStatus
    /// Transcript text.
    public let transcript: String
    /// Main audio file path.
    public let audioPath: URL

    /// Creates a persisted session value.
    public init(
        sessionID: UUID,
        createdAt: Date,
        durationMS: Int,
        providerPrimary: ProviderKind,
        providerUsed: ProviderKind,
        language: String,
        outputMode: OutputMode,
        status: SessionStatus,
        transcript: String,
        audioPath: URL
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.durationMS = durationMS
        self.providerPrimary = providerPrimary
        self.providerUsed = providerUsed
        self.language = language
        self.outputMode = outputMode
        self.status = status
        self.transcript = transcript
        self.audioPath = audioPath
    }
}
