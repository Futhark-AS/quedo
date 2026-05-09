import XCTest
@testable import QuedoCore

final class ConfigurationTests: XCTestCase {
    func testDefaultSettingsLoadWhenUnset() async throws {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ConfigurationManager(userDefaults: defaults, sharedConfigEnabled: false)
        let settings = try await manager.loadSettings()

        XCTAssertEqual(settings.outputMode, .clipboardAndPaste)
        XCTAssertEqual(settings.provider.primary, .groq)
    }

    func testValidationAggregatesErrors() async {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ConfigurationManager(userDefaults: defaults, sharedConfigEnabled: false)
        var invalid = AppSettings.default
        invalid.provider.timeoutSeconds = 0
        invalid.hotkeys = []
        invalid.provider.fallback = invalid.provider.primary

        do {
            try await manager.validate(settings: invalid)
            XCTFail("Expected aggregated validation failure")
        } catch let error as SettingsValidationErrorSet {
            XCTAssertGreaterThanOrEqual(error.issues.count, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidationAllowsNoHotkeys() async throws {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ConfigurationManager(userDefaults: defaults, sharedConfigEnabled: false)
        var settings = AppSettings.default
        settings.hotkeys = []

        try await manager.validate(settings: settings)
    }

    func testSaveAndReloadSettings() async throws {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ConfigurationManager(userDefaults: defaults, sharedConfigEnabled: false)
        var settings = AppSettings.default
        settings.language = "en"
        settings.outputMode = .clipboard

        try await manager.saveSettings(settings)
        let loaded = try await manager.loadSettings()

        XCTAssertEqual(loaded.language, "en")
        XCTAssertEqual(loaded.outputMode, .clipboard)
    }

    func testSaveAndReloadMultipleRecordingProfiles() async throws {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ConfigurationManager(userDefaults: defaults, sharedConfigEnabled: false)
        var settings = AppSettings.default
        let norwegian = RecordingShortcutProfile(
            id: "norwegian",
            name: "Norwegian",
            hotkey: HotkeyBinding(actionID: "recording.norwegian", keyCode: 18, modifiers: [.control, .option]),
            provider: .elevenLabs,
            fallbackProvider: .openAI,
            model: "scribe_v2",
            fallbackModel: "gpt-4o-mini-transcribe",
            language: "no"
        )
        settings.recordingProfiles.append(norwegian)
        settings.hotkeys.append(norwegian.hotkey)
        settings.provider.elevenLabsModel = "scribe_v2"

        try await manager.saveSettings(settings)
        let loaded = try await manager.loadSettings()

        XCTAssertEqual(loaded.recordingProfiles.count, 2)
        XCTAssertEqual(loaded.recordingProfiles.last?.provider, .elevenLabs)
        XCTAssertEqual(loaded.recordingProfiles.last?.fallbackProvider, .openAI)
        XCTAssertEqual(loaded.recordingProfiles.last?.model, "scribe_v2")
        XCTAssertEqual(loaded.recordingProfiles.last?.fallbackModel, "gpt-4o-mini-transcribe")
        XCTAssertEqual(loaded.recordingProfiles.last?.language, "no")
        XCTAssertTrue(loaded.hotkeys.contains(norwegian.hotkey))
    }

    func testSharedConfigDoesNotCollapsePersistedRecordingProfiles() async throws {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let configHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configHome) }

        let manager = ConfigurationManager(
            userDefaults: defaults,
            sharedConfigEnabled: true,
            configHomeDirectoryURL: configHome
        )
        var settings = AppSettings.default
        let scribe = RecordingShortcutProfile(
            id: "scribe",
            name: "Scribe",
            hotkey: HotkeyBinding(actionID: "recording.scribe", keyCode: 5, modifiers: [.control, .shift, .option, .command]),
            provider: .elevenLabs,
            fallbackProvider: .openAI,
            model: "scribe_v2",
            fallbackModel: "gpt-4o-mini-transcribe",
            language: "no"
        )
        settings.recordingProfiles.append(scribe)
        settings.hotkeys.append(scribe.hotkey)

        try await manager.saveSettings(settings)
        let loaded = try await manager.loadSettings()

        XCTAssertEqual(loaded.recordingProfiles.count, 2)
        XCTAssertTrue(loaded.recordingProfiles.contains(scribe))
        XCTAssertTrue(loaded.hotkeys.contains(scribe.hotkey))
    }

    func testLegacyProviderConfigDecodesWithoutWhisperCppModelPath() throws {
        let legacyJSON = """
        {
          "provider": {
            "primary": "groq",
            "fallback": "openAI",
            "groqAPIKeyRef": "groq_api_key",
            "openAIAPIKeyRef": "openai_api_key",
            "timeoutSeconds": 12,
            "groqModel": "whisper-large-v3",
            "openAIModel": "gpt-4o-mini-transcribe"
          }
        }
        """

        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.provider.primary, .groq)
        XCTAssertEqual(decoded.provider.fallback, .openAI)
        XCTAssertEqual(decoded.provider.whisperCppModelPath, ProviderConfiguration.defaultValue.whisperCppModelPath)
        XCTAssertEqual(decoded.provider.whisperCppRuntime, .auto)
    }

    func testLegacySettingsCreateDefaultRecordingProfileFromToggleHotkey() throws {
        let legacyJSON = """
        {
          "language": "en",
          "hotkeys": [
            { "actionID": "toggle", "keyCode": 18, "modifiers": 12 },
            { "actionID": "retry", "keyCode": 19, "modifiers": 12 }
          ],
          "provider": {
            "primary": "openAI",
            "fallback": "groq",
            "openAIModel": "gpt-4o-mini-transcribe"
          }
        }
        """

        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.recordingProfiles.count, 1)
        XCTAssertEqual(decoded.recordingProfiles[0].hotkey.actionID, "recording.default")
        XCTAssertEqual(decoded.recordingProfiles[0].hotkey.keyCode, 18)
        XCTAssertEqual(decoded.recordingProfiles[0].provider, .openAI)
        XCTAssertEqual(decoded.recordingProfiles[0].fallbackProvider, .groq)
        XCTAssertEqual(decoded.recordingProfiles[0].fallbackModel, "whisper-large-v3")
        XCTAssertEqual(decoded.recordingProfiles[0].language, "en")
    }

    func testValidationRejectsDuplicateProfileShortcutsAndSameFallback() async {
        let suiteName = "ConfigurationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ConfigurationManager(userDefaults: defaults, sharedConfigEnabled: false)
        let first = RecordingShortcutProfile(
            id: "first",
            name: "First",
            hotkey: HotkeyBinding(actionID: "recording.first", keyCode: 18, modifiers: [.control, .option]),
            provider: .groq,
            fallbackProvider: .openAI,
            model: "whisper-large-v3",
            fallbackModel: "gpt-4o-mini-transcribe",
            language: "en"
        )
        let second = RecordingShortcutProfile(
            id: "second",
            name: "Second",
            hotkey: HotkeyBinding(actionID: "recording.second", keyCode: 18, modifiers: [.control, .option]),
            provider: .elevenLabs,
            fallbackProvider: .elevenLabs,
            model: "scribe_v2",
            fallbackModel: "scribe_v2",
            language: "no"
        )
        var settings = AppSettings.default
        settings.recordingProfiles = [first, second]
        settings.hotkeys = [first.hotkey, second.hotkey]

        do {
            try await manager.validate(settings: settings)
            XCTFail("Expected profile validation errors")
        } catch let error as SettingsValidationErrorSet {
            XCTAssertTrue(error.issues.contains { $0.field == "recordingProfiles.second.hotkey" })
            XCTAssertTrue(error.issues.contains { $0.field == "recordingProfiles.second.fallbackProvider" })
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
