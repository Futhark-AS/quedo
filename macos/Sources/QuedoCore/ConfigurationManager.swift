import Foundation
import Security

/// Errors returned by configuration operations.
public enum ConfigurationError: Error, Sendable {
    /// Settings payload is missing or corrupted.
    case settingsNotFound
    /// Keychain operation failed.
    case keychainFailure(status: OSStatus)
}

/// Manages persisted settings and secrets with validation.
public actor ConfigurationManager {
    private enum Constants {
        static let userDefaultsKey = "quedo.settings.v1"
        static let legacyUserDefaultsKey = "whisper.assistant.settings.v1"
        static let keychainService = "com.futhark.quedo.keys"
        static let legacyKeychainService = "com.whisperassistant.keys"
        static let secretsFileName = "api-keys.json"
        static let sharedConfigDirectoryName = "quedo"
        static let legacySharedConfigDirectoryName = "whisper-assistant"
        static let sharedConfigFileName = "config.env"
        static let appSupportDirectoryName = "Quedo"
        static let legacyAppSupportDirectoryName = "Whisper Assistant"

        static let envGroqAPIKey = "GROQ_API_KEY"
        static let envOpenAIAPIKey = "OPENAI_API_KEY"
        static let envElevenLabsAPIKey = "ELEVENLABS_API_KEY"
        static let envToggleHotkey = "TOGGLE_RECORDING_HOTKEY"
        static let envRetryHotkey = "RETRY_TRANSCRIPTION_HOTKEY"
        static let envCancelHotkey = "CANCEL_RECORDING_HOTKEY"
        static let envLanguage = "TRANSCRIPTION_LANGUAGE"
        static let envOutput = "TRANSCRIPTION_OUTPUT"
        static let envLaunchAtLogin = "LAUNCH_AT_LOGIN"
        static let envWhisperModel = "WHISPER_MODEL"
        static let envWhisperCppModelPath = "WHISPER_CPP_MODEL_PATH"
        static let envWhisperCppRuntime = "WHISPER_CPP_RUNTIME"
        static let envElevenLabsModel = "ELEVENLABS_MODEL"
        static let envTimeout = "GROQ_TIMEOUT"
        static let envVocabulary = "VOCABULARY"
    }

    private let userDefaults: UserDefaults
    private let sharedConfigEnabled: Bool
    private let configHomeDirectoryOverride: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Creates a configuration manager.
    public init(
        userDefaults: UserDefaults = .standard,
        sharedConfigEnabled: Bool = true,
        configHomeDirectoryURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.sharedConfigEnabled = sharedConfigEnabled
        self.configHomeDirectoryOverride = configHomeDirectoryURL
    }

    /// Loads persisted settings or returns defaults when not yet configured.
    public func loadSettings() throws -> AppSettings {
        var settings = AppSettings.default

        var loadedLocalSettings = false
        if let data = userDefaults.data(forKey: Constants.userDefaultsKey) ?? userDefaults.data(forKey: Constants.legacyUserDefaultsKey) {
            do {
                settings = try decoder.decode(AppSettings.self, from: data)
                loadedLocalSettings = true
            } catch {
                // Corrupt local settings should not block fallback to shared config.
                settings = .default
            }
        }

        if sharedConfigEnabled, let shared = try loadSettingsFromSharedConfig(base: settings, preserveLocalHotkeys: loadedLocalSettings) {
            settings = shared
        }

        try validate(settings: settings)
        return settings
    }

    /// Validates and stores settings in UserDefaults.
    public func saveSettings(_ settings: AppSettings) throws {
        try validate(settings: settings)
        let data = try encoder.encode(settings)
        userDefaults.set(data, forKey: Constants.userDefaultsKey)
        userDefaults.removeObject(forKey: Constants.legacyUserDefaultsKey)
        if sharedConfigEnabled {
            try saveSettingsToSharedConfig(settings)
        }
    }

    /// Stores provider API key in Keychain.
    public func saveAPIKey(_ key: String, for provider: ProviderKind) throws {
        if provider == .whisperCpp {
            return
        }
        var secrets = try loadLocalSecrets()
        secrets[provider.rawValue] = key
        try saveLocalSecrets(secrets)

        if sharedConfigEnabled {
            var sharedConfig = try loadSharedConfigValues()
            switch provider {
            case .groq:
                sharedConfig[Constants.envGroqAPIKey] = key
            case .openAI:
                sharedConfig[Constants.envOpenAIAPIKey] = key
            case .elevenLabs:
                sharedConfig[Constants.envElevenLabsAPIKey] = key
            case .whisperCpp:
                break
            }
            try saveSharedConfigValues(sharedConfig)
        }

        // Best effort: delete legacy keychain item to avoid repeated access prompts.
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.keychainService,
            kSecAttrAccount: provider.rawValue
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let legacyDeleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.legacyKeychainService,
            kSecAttrAccount: provider.rawValue
        ]
        SecItemDelete(legacyDeleteQuery as CFDictionary)
    }

    /// Removes provider API key from local and shared stores.
    public func clearAPIKey(for provider: ProviderKind) throws {
        if provider == .whisperCpp {
            return
        }
        var secrets = try loadLocalSecrets()
        secrets.removeValue(forKey: provider.rawValue)
        try saveLocalSecrets(secrets)

        if sharedConfigEnabled {
            var sharedConfig = try loadSharedConfigValues()
            switch provider {
            case .groq:
                sharedConfig.removeValue(forKey: Constants.envGroqAPIKey)
            case .openAI:
                sharedConfig.removeValue(forKey: Constants.envOpenAIAPIKey)
            case .elevenLabs:
                sharedConfig.removeValue(forKey: Constants.envElevenLabsAPIKey)
            case .whisperCpp:
                break
            }
            try saveSharedConfigValues(sharedConfig)
        }

        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.keychainService,
            kSecAttrAccount: provider.rawValue
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let legacyDeleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.legacyKeychainService,
            kSecAttrAccount: provider.rawValue
        ]
        SecItemDelete(legacyDeleteQuery as CFDictionary)
    }

    /// Reads provider API key from local secrets first, then keychain fallback.
    public func loadAPIKey(for provider: ProviderKind) throws -> String? {
        if provider == .whisperCpp {
            return nil
        }

        let localSecrets = try loadLocalSecrets()
        if let local = localSecrets[provider.rawValue], !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return local
        }

        if sharedConfigEnabled {
            let sharedConfig = try loadSharedConfigValues()
            let sharedKeyName: String
            switch provider {
            case .groq:
                sharedKeyName = Constants.envGroqAPIKey
            case .openAI:
                sharedKeyName = Constants.envOpenAIAPIKey
            case .elevenLabs:
                sharedKeyName = Constants.envElevenLabsAPIKey
            case .whisperCpp:
                return nil
            }
            if let shared = sharedConfig[sharedKeyName], !shared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var updated = localSecrets
                updated[provider.rawValue] = shared
                try? saveLocalSecrets(updated)
                return shared
            }
        }

        guard let migrated = try loadAPIKeyFromKeychain(for: provider) else {
            return nil
        }

        // Migrate keychain value to local secrets to eliminate repeated keychain prompts.
        var updated = localSecrets
        updated[provider.rawValue] = migrated
        try? saveLocalSecrets(updated)
        return migrated
    }

    private func loadAPIKeyFromKeychain(for provider: ProviderKind) throws -> String? {
        if let current = try readKeychainItem(for: provider, service: Constants.keychainService) {
            return current
        }
        return try readKeychainItem(for: provider, service: Constants.legacyKeychainService)
    }

    private func readKeychainItem(for provider: ProviderKind, service: String) throws -> String? {
        let account = provider.rawValue
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw ConfigurationError.keychainFailure(status: status)
        }

        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    private func loadLocalSecrets() throws -> [String: String] {
        let path = secretsFileURL()
        guard FileManager.default.fileExists(atPath: path.path) else {
            return [:]
        }

        let data = try Data(contentsOf: path)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        return decoded
    }

    private func saveLocalSecrets(_ secrets: [String: String]) throws {
        let fileURL = secretsFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(secrets)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func secretsFileURL() -> URL {
        let appSupport = appSupportDirectoryURL()
        return appSupport.appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent(Constants.secretsFileName)
    }

    private func loadSettingsFromSharedConfig(base: AppSettings, preserveLocalHotkeys: Bool) throws -> AppSettings? {
        let shared = try loadSharedConfigValues()
        guard !shared.isEmpty else {
            return nil
        }

        var settings = base

        if let language = shared[Constants.envLanguage]?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            settings.language = language.lowercased() == "auto" ? "auto" : language
        }

        if let outputValue = shared[Constants.envOutput] {
            settings.outputMode = parseSharedOutputMode(outputValue)
        }

        if let launchAtLoginValue = shared[Constants.envLaunchAtLogin], let launchAtLogin = parseSharedBool(launchAtLoginValue) {
            settings.launchAtLoginEnabled = launchAtLogin
        }

        if let model = shared[Constants.envWhisperModel]?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            settings.provider.groqModel = model
        }
        if let whisperCppModelPath = shared[Constants.envWhisperCppModelPath]?.trimmingCharacters(in: .whitespacesAndNewlines), !whisperCppModelPath.isEmpty {
            settings.provider.whisperCppModelPath = whisperCppModelPath
        }
        if let runtime = shared[Constants.envWhisperCppRuntime]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let parsedRuntime = WhisperCppRuntime(rawValue: runtime) {
            settings.provider.whisperCppRuntime = parsedRuntime
        }
        if let model = shared[Constants.envElevenLabsModel]?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            settings.provider.elevenLabsModel = model
        }

        if let timeoutRaw = shared[Constants.envTimeout], let parsed = Int(timeoutRaw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            settings.provider.timeoutSeconds = min(max(parsed, 1), 120)
        }

        if let vocabularyRaw = shared[Constants.envVocabulary] {
            settings.vocabularyHints = vocabularyRaw
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        if !preserveLocalHotkeys {
            var parsedHotkeys: [HotkeyBinding] = []
            if let toggle = parseSharedHotkey(shared[Constants.envToggleHotkey], actionID: "toggle") {
                let profileHotkey = HotkeyBinding(actionID: "recording.default", keyCode: toggle.keyCode, modifiers: toggle.modifiers)
                settings.recordingProfiles = [
                    RecordingShortcutProfile(
                        id: "default",
                        name: "Default",
                        hotkey: profileHotkey,
                        provider: settings.provider.primary,
                        fallbackProvider: settings.provider.fallback,
                        model: model(for: settings.provider.primary, provider: settings.provider),
                        fallbackModel: model(for: settings.provider.fallback, provider: settings.provider),
                        language: settings.language
                    )
                ]
                parsedHotkeys.append(profileHotkey)
            }
            if let retry = parseSharedHotkey(shared[Constants.envRetryHotkey], actionID: "retry") {
                parsedHotkeys.append(retry)
            }
            if let cancel = parseSharedHotkey(shared[Constants.envCancelHotkey], actionID: "cancel") {
                parsedHotkeys.append(cancel)
            }
            if !parsedHotkeys.isEmpty {
                settings.hotkeys = parsedHotkeys
            }
        }

        try validate(settings: settings)
        return settings
    }

    private func saveSettingsToSharedConfig(_ settings: AppSettings) throws {
        var shared = try loadSharedConfigValues()

        shared[Constants.envLanguage] = settings.language.isEmpty ? "auto" : settings.language
        shared[Constants.envOutput] = sharedOutputString(settings.outputMode)
        shared[Constants.envLaunchAtLogin] = settings.launchAtLoginEnabled ? "true" : "false"
        shared[Constants.envWhisperModel] = settings.provider.groqModel
        shared[Constants.envWhisperCppModelPath] = settings.provider.whisperCppModelPath
        shared[Constants.envWhisperCppRuntime] = settings.provider.whisperCppRuntime.rawValue
        shared[Constants.envElevenLabsModel] = settings.provider.elevenLabsModel
        shared[Constants.envTimeout] = String(settings.provider.timeoutSeconds)
        shared[Constants.envVocabulary] = settings.vocabularyHints.joined(separator: ",")

        let byAction = Dictionary(uniqueKeysWithValues: settings.hotkeys.map { ($0.actionID, $0) })
        if let toggle = settings.hotkeys.first(where: { $0.actionID.hasPrefix("recording.") }), let rendered = renderSharedHotkey(toggle) {
            shared[Constants.envToggleHotkey] = rendered
        }
        if let retry = byAction["retry"], let rendered = renderSharedHotkey(retry) {
            shared[Constants.envRetryHotkey] = rendered
        }
        if let cancel = byAction["cancel"], let rendered = renderSharedHotkey(cancel) {
            shared[Constants.envCancelHotkey] = rendered
        }

        try saveSharedConfigValues(shared)
    }

    private func loadSharedConfigValues() throws -> [String: String] {
        let fileManager = FileManager.default
        var path = sharedConfigFileURL()
        if !fileManager.fileExists(atPath: path.path) {
            let legacy = legacySharedConfigFileURL()
            guard fileManager.fileExists(atPath: legacy.path) else {
                return [:]
            }
            path = legacy
        }

        let content = try String(contentsOf: path, encoding: .utf8)
        var result: [String: String] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }

        return result
    }

    private func saveSharedConfigValues(_ values: [String: String]) throws {
        let fileURL = sharedConfigFileURL()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let orderedKeys: [String] = [
            Constants.envGroqAPIKey,
            Constants.envOpenAIAPIKey,
            Constants.envElevenLabsAPIKey,
            Constants.envToggleHotkey,
            Constants.envRetryHotkey,
            Constants.envCancelHotkey,
            Constants.envLanguage,
            Constants.envOutput,
            Constants.envLaunchAtLogin,
            Constants.envWhisperModel,
            Constants.envWhisperCppModelPath,
            Constants.envWhisperCppRuntime,
            Constants.envElevenLabsModel,
            Constants.envTimeout,
            Constants.envVocabulary
        ]

        let extras = values.keys.filter { !orderedKeys.contains($0) }.sorted()
        let finalOrder = orderedKeys + extras

        var lines: [String] = ["# Managed by Quedo macOS app"]
        for key in finalOrder {
            guard let value = values[key] else {
                continue
            }
            lines.append("\(key)=\(value)")
        }

        try lines.joined(separator: "\n").appending("\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func sharedConfigFileURL() -> URL {
        configHomeDirectoryURL()
            .appendingPathComponent(Constants.sharedConfigDirectoryName, isDirectory: true)
            .appendingPathComponent(Constants.sharedConfigFileName)
    }

    private func legacySharedConfigFileURL() -> URL {
        configHomeDirectoryURL()
            .appendingPathComponent(Constants.legacySharedConfigDirectoryName, isDirectory: true)
            .appendingPathComponent(Constants.sharedConfigFileName)
    }

    private func configHomeDirectoryURL() -> URL {
        if let configHomeDirectoryOverride {
            return configHomeDirectoryOverride
        }
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }

    private func appSupportDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent(Constants.appSupportDirectoryName, isDirectory: true)
        let legacy = base.appendingPathComponent(Constants.legacyAppSupportDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: current)
        }
        return current
    }

    private func parseSharedOutputMode(_ value: String) -> OutputMode {
        let options = Set(
            value
                .lowercased()
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )

        if options.contains("none") || options.isEmpty {
            return .none
        }

        let clipboard = options.contains("clipboard")
        let paste = options.contains("paste_on_cursor")

        switch (clipboard, paste) {
        case (true, true):
            return .clipboardAndPaste
        case (true, false):
            return .clipboard
        case (false, true):
            return .pasteAtCursor
        default:
            return .none
        }
    }

    private func sharedOutputString(_ mode: OutputMode) -> String {
        switch mode {
        case .none:
            return "none"
        case .clipboard:
            return "clipboard"
        case .pasteAtCursor:
            return "paste_on_cursor"
        case .clipboardAndPaste:
            return "clipboard,paste_on_cursor"
        }
    }

    private func parseSharedHotkey(_ value: String?, actionID: String) -> HotkeyBinding? {
        guard let value else { return nil }
        return HotkeyCodec.parse(value, actionID: actionID)
    }

    private func renderSharedHotkey(_ binding: HotkeyBinding) -> String? {
        HotkeyCodec.render(binding)
    }

    private func model(for kind: ProviderKind, provider: ProviderConfiguration) -> String {
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

    private func parseSharedBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// Validates all settings and throws aggregated failures.
    public func validate(settings: AppSettings) throws {
        var issues: [SettingsValidationIssue] = []
        let allowedHotkeyActions: Set<String> = ["toggle", "retry", "cancel"]

        if settings.provider.timeoutSeconds < 1 || settings.provider.timeoutSeconds > 120 {
            issues.append(SettingsValidationIssue(field: "provider.timeoutSeconds", message: "Timeout must be between 1 and 120 seconds"))
        }

        let validModes = Set(OutputMode.allCases)
        if !validModes.contains(settings.outputMode) {
            issues.append(SettingsValidationIssue(field: "outputMode", message: "Unsupported output mode"))
        }

        if settings.provider.primary == settings.provider.fallback {
            issues.append(SettingsValidationIssue(field: "provider.fallback", message: "Primary and fallback provider must differ"))
        }

        let normalizedLanguage = settings.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedLanguage.isEmpty {
            issues.append(SettingsValidationIssue(field: "language", message: "Language cannot be empty"))
        }

        var seenActions = Set<String>()
        for hotkey in settings.hotkeys {
            if !allowedHotkeyActions.contains(hotkey.actionID), !hotkey.actionID.hasPrefix("recording.") {
                issues.append(SettingsValidationIssue(field: "hotkeys.\(hotkey.actionID)", message: "Unsupported actionID"))
            }
            if seenActions.contains(hotkey.actionID) {
                issues.append(SettingsValidationIssue(field: "hotkeys", message: "Duplicate actionID \(hotkey.actionID)"))
            }
            seenActions.insert(hotkey.actionID)

            if hotkey.modifiers.isEmpty {
                issues.append(SettingsValidationIssue(field: "hotkeys.\(hotkey.actionID)", message: "At least one modifier is required"))
            }
        }

        if settings.provider.groqModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(SettingsValidationIssue(field: "provider.groqModel", message: "Groq model must not be empty"))
        }

        if settings.provider.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(SettingsValidationIssue(field: "provider.openAIModel", message: "OpenAI model must not be empty"))
        }

        if settings.provider.elevenLabsModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(SettingsValidationIssue(field: "provider.elevenLabsModel", message: "ElevenLabs model must not be empty"))
        }

        var seenProfileIDs = Set<String>()
        var seenProfileHotkeys = Set<HotkeyBinding>()
        for profile in settings.recordingProfiles {
            let normalizedID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedID.isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.id", message: "Profile id must not be empty"))
            }
            if seenProfileIDs.contains(normalizedID) {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(normalizedID)", message: "Duplicate profile id"))
            }
            seenProfileIDs.insert(normalizedID)

            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(normalizedID).name", message: "Profile name must not be empty"))
            }
            if profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(normalizedID).model", message: "Profile model must not be empty"))
            }
            if profile.fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(normalizedID).fallbackModel", message: "Profile fallback model must not be empty"))
            }
            if profile.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(normalizedID).language", message: "Profile language must not be empty"))
            }
            if profile.hotkey.actionID != profile.actionID {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(normalizedID).hotkey", message: "Profile hotkey actionID must match profile id"))
            }
            let normalizedHotkey = HotkeyBinding(actionID: "", keyCode: profile.hotkey.keyCode, modifiers: profile.hotkey.modifiers)
            if seenProfileHotkeys.contains(normalizedHotkey) {
                issues.append(
                    SettingsValidationIssue(
                        field: "recordingProfiles.\(normalizedID).hotkey",
                        message: "Duplicate recording shortcut"
                    )
                )
            }
            seenProfileHotkeys.insert(normalizedHotkey)
            if profile.provider == profile.fallbackProvider {
                issues.append(
                    SettingsValidationIssue(
                        field: "recordingProfiles.\(normalizedID).fallbackProvider",
                        message: "Profile provider and fallback must differ"
                    )
                )
            }
        }

        let usesWhisperCpp = settings.provider.primary == .whisperCpp || settings.provider.fallback == .whisperCpp
        let hasWhisperCppProfile = settings.recordingProfiles.contains { $0.provider == .whisperCpp || $0.fallbackProvider == .whisperCpp }
        if (usesWhisperCpp || hasWhisperCppProfile), settings.provider.whisperCppModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                SettingsValidationIssue(
                    field: "provider.whisperCppModelPath",
                    message: "whisper.cpp model path must not be empty when whisper.cpp is enabled"
                )
            )
        }

        if issues.isEmpty {
            return
        }

        throw SettingsValidationErrorSet(issues: issues)
    }

    /// Produces sanitized settings snapshot for diagnostics and CLI output.
    public func redactedSnapshot() throws -> [String: String] {
        let settings = try loadSettings()
        return [
            "buildProfile": settings.buildProfile.rawValue,
            "outputMode": settings.outputMode.rawValue,
            "language": settings.language,
            "recordingInteraction": settings.recordingInteraction.rawValue,
            "launchAtLoginEnabled": settings.launchAtLoginEnabled ? "true" : "false",
            "primaryProvider": settings.provider.primary.rawValue,
            "fallbackProvider": settings.provider.fallback.rawValue,
            "timeoutSeconds": String(settings.provider.timeoutSeconds),
            "groqModel": settings.provider.groqModel,
            "openAIModel": settings.provider.openAIModel,
            "whisperCppModelPath": settings.provider.whisperCppModelPath,
            "whisperCppRuntime": settings.provider.whisperCppRuntime.rawValue,
            "elevenLabsModel": settings.provider.elevenLabsModel,
            "recordingProfilesCount": String(settings.recordingProfiles.count),
            "vocabularyHintsCount": String(settings.vocabularyHints.count)
        ]
    }
}
