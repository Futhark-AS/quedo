import AppKit
import Carbon
import SwiftUI
import QuedoCore

/// Preset hotkey layouts exposed in preferences.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case fnControl = "Fn + Ctrl (Recommended)"
    case ctrlShift = "Ctrl + Shift (Legacy)"
    case manual = "Manual (Custom Strings)"

    var id: String { rawValue }
}

struct WhisperCppInstallPreset: Hashable {
    let variant: String
    let title: String
    let detail: String
    let approxSizeGB: Double

    var fileName: String {
        "ggml-\(variant).bin"
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var sizeLabel: String {
        String(format: "~%.1f GB", approxSizeGB)
    }
}

struct WhisperCppInstalledModel: Hashable {
    let path: String
    let sizeBytes: Int64

    var sizeLabel: String {
        String(format: "%.1f GB", Double(sizeBytes) / 1_000_000_000.0)
    }
}

struct EditableRecordingProfile: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var hotkeyText: String
    var provider: ProviderKind
    var fallbackProvider: ProviderKind
    var model: String
    var fallbackModel: String
    var language: String
}

private enum PreferencesPane: String, CaseIterable, Identifiable {
    case general
    case recordingProfiles
    case providerSetup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recordingProfiles: return "Recording Profiles"
        case .providerSetup: return "Provider Setup"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            return "Output, interaction, and launch behavior."
        case .recordingProfiles:
            return "Shortcuts, providers, models, and languages."
        case .providerSetup:
            return "Credentials, local models, and defaults."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .recordingProfiles: return "keyboard"
        case .providerSetup: return "network"
        }
    }
}

private struct PreferencesCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

/// Preferences window for application configuration.
struct PreferencesView: View {
    @StateObject private var model: PreferencesViewModel
    @State private var selectedPane: PreferencesPane = .general

    private let rowLabelWidth: CGFloat = 130

    init(
        configurationManager: ConfigurationManager,
        onSaved: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        _model = StateObject(
            wrappedValue: PreferencesViewModel(
                configurationManager: configurationManager,
                onSaved: onSaved
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            List(PreferencesPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationTitle("Preferences")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedPane.title)
                        .font(.title2.weight(.semibold))
                    Text(selectedPane.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        paneContent(for: selectedPane)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Restore Defaults") {
                        model.applyDefaults()
                    }
                    .disabled(model.isSaving)

                    Button("Discard Changes") {
                        model.discardChanges()
                    }
                    .disabled(!model.hasUnsavedChanges || model.isSaving)

                    Spacer()

                    if model.hasUnsavedChanges {
                        Label("Unsaved changes", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let status = model.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(model.statusIsError ? .red : .secondary)
                            .lineLimit(2)
                    }

                    Button(model.isSaving ? "Saving..." : "Save Changes") {
                        Task { await model.save() }
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSave)
                }
                .padding(16)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 680)
        .task {
            await model.load()
        }
        .animation(.easeInOut(duration: 0.15), value: selectedPane)
    }

    @ViewBuilder
    private func paneContent(for pane: PreferencesPane) -> some View {
        switch pane {
        case .general:
            generalPane
        case .providerSetup:
            providersPane
        case .recordingProfiles:
            hotkeysPane
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesCard(
                title: "Behavior",
                subtitle: "Core app interaction and output delivery."
            ) {
                settingRow("Interaction") {
                    Picker("", selection: $model.recordingInteraction) {
                        Text("Toggle").tag(RecordingInteractionMode.toggle)
                        Text("Hold").tag(RecordingInteractionMode.hold)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }

                settingRow("Output") {
                    Picker("", selection: $model.outputMode) {
                        ForEach(OutputMode.allCases, id: \.self) { mode in
                            Text(outputLabel(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }

                settingRow("Launch at login") {
                    Toggle("", isOn: $model.launchAtLoginEnabled)
                        .labelsHidden()
                }

            }

            PreferencesCard(
                title: "Vocabulary Hints",
                subtitle: "Paste one term per line, or comma-separated."
            ) {
                TextEditor(text: $model.vocabularyText)
                    .font(.body)
                    .padding(8)
                    .frame(minHeight: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Button("Paste from Clipboard") {
                        model.pasteVocabulary()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        model.clearVocabulary()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("\(model.vocabularyHintCount) hints")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var providersPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesCard(
                title: "Provider Defaults",
                subtitle: "Defaults used by CLI, migrations, and new recording profiles."
            ) {
                settingRow("Timeout") {
                    Stepper(value: $model.timeoutSeconds, in: 1...120) {
                        Text("\(model.timeoutSeconds) seconds")
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }

                settingRow("Groq model") {
                    TextField("whisper-large-v3", text: $model.groqModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 340)
                }

                settingRow("OpenAI model") {
                    TextField("gpt-4o-mini-transcribe", text: $model.openAIModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 340)
                }

                settingRow("ElevenLabs model") {
                    TextField("scribe_v2", text: $model.elevenLabsModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 340)
                }

                settingRow("whisper.cpp model") {
                    TextField("ggml-large-v3.bin or /abs/path/model.bin", text: $model.whisperCppModelPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 520)
                }

                settingRow("Detected models") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button("Refresh") {
                                model.refreshWhisperCppModels()
                            }
                            .buttonStyle(.bordered)

                            Text("\(model.availableWhisperCppModels.count) installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.availableWhisperCppModels.isEmpty {
                            Text("No local .bin models detected in whisper model directories.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.availableWhisperCppModels, id: \.path) { installed in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(whisperCppModelLabel(installed.path))
                                            .font(.caption)
                                        Text(installed.sizeLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if model.whisperCppModelPath == installed.path {
                                        Text("Selected")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Button("Use") {
                                        model.whisperCppModelPath = installed.path
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.whisperCppModelPath == installed.path)

                                    Button("Delete") {
                                        model.deleteWhisperCppModel(installed.path)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isInstallingWhisperCppModel)
                                }
                            }
                        }
                    }
                }

                settingRow("Download models") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Menu("Download Whisper Model") {
                                ForEach(model.whisperCppInstallPresets, id: \.variant) { preset in
                                    Button {
                                        Task { await model.installWhisperCppModel(preset) }
                                    } label: {
                                        Text("\(preset.title) (\(preset.sizeLabel), \(preset.detail))")
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .disabled(model.isInstallingWhisperCppModel)

                            if model.isInstallingWhisperCppModel {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if let activeDownload = model.activeWhisperCppDownloadTitle {
                            Text("Downloading \(activeDownload)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("Downloads to ~/.cache/whisper, verifies response, and selects model when complete.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                settingRow("whisper.cpp runtime") {
                    Picker("", selection: $model.whisperCppRuntime) {
                        ForEach(WhisperCppRuntime.allCases, id: \.self) { runtime in
                            Text(whisperCppRuntimeLabel(runtime)).tag(runtime)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }
            }

            apiKeysPane
        }
    }

    private var apiKeysPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesCard(
                title: "Groq",
                subtitle: "Used by recording profiles that select Groq."
            ) {
                settingRow("API key") {
                    HStack(spacing: 8) {
                        SecureField("Paste new key (optional)", text: $model.groqAPIKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 400)

                        Label(
                            model.hasGroqKey ? "Stored" : "Missing",
                            systemImage: model.hasGroqKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(model.hasGroqKey ? Color.accentColor : Color.orange)
                    }
                }

                HStack(spacing: 8) {
                    Button("Paste") {
                        model.pasteAPIKey(.groq)
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Input") {
                        model.clearAPIKeyInput(.groq)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.groqAPIKeyInput.isEmpty)

                    Spacer()

                    Button("Remove Stored Key", role: .destructive) {
                        Task { await model.clearStoredAPIKey(.groq) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasGroqKey || model.isSaving)
                }
            }

            PreferencesCard(
                title: "OpenAI",
                subtitle: "Used by recording profiles that select OpenAI."
            ) {
                settingRow("API key") {
                    HStack(spacing: 8) {
                        SecureField("Paste new key (optional)", text: $model.openAIAPIKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 400)

                        Label(
                            model.hasOpenAIKey ? "Stored" : "Missing",
                            systemImage: model.hasOpenAIKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(model.hasOpenAIKey ? Color.accentColor : Color.orange)
                    }
                }

                HStack(spacing: 8) {
                    Button("Paste") {
                        model.pasteAPIKey(.openAI)
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Input") {
                        model.clearAPIKeyInput(.openAI)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.openAIAPIKeyInput.isEmpty)

                    Spacer()

                    Button("Remove Stored Key", role: .destructive) {
                        Task { await model.clearStoredAPIKey(.openAI) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasOpenAIKey || model.isSaving)
                }
            }

            PreferencesCard(
                title: "ElevenLabs",
                subtitle: "Required when ElevenLabs Scribe is selected."
            ) {
                settingRow("API key") {
                    HStack(spacing: 8) {
                        SecureField("Paste new key (optional)", text: $model.elevenLabsAPIKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 400)

                        Label(
                            model.hasElevenLabsKey ? "Stored" : "Missing",
                            systemImage: model.hasElevenLabsKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(model.hasElevenLabsKey ? Color.accentColor : Color.orange)
                    }
                }

                HStack(spacing: 8) {
                    Button("Paste") {
                        model.pasteAPIKey(.elevenLabs)
                    }
                    .buttonStyle(.bordered)

                    Button("Clear Input") {
                        model.clearAPIKeyInput(.elevenLabs)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.elevenLabsAPIKeyInput.isEmpty)

                    Spacer()

                    Button("Remove Stored Key", role: .destructive) {
                        Task { await model.clearStoredAPIKey(.elevenLabs) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.hasElevenLabsKey || model.isSaving)
                }
            }
        }
    }

    private var hotkeysPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesCard(
                title: "Recording Profiles",
                subtitle: "Each recording shortcut owns its provider, fallback, model, and language."
            ) {
                settingRow("Enable hotkeys") {
                    Toggle("", isOn: $model.hotkeysEnabled)
                        .labelsHidden()
                }

                if model.hotkeysEnabled {
                    settingRow("Shortcut mode") {
                        Picker("", selection: $model.hotkeyPreset) {
                            ForEach(model.availableHotkeyPresets, id: \.self) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 280)
                    }

                    Text(model.hotkeySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, rowLabelWidth + 12)
                } else {
                    Text("Hotkeys disabled. Use menu bar actions only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, rowLabelWidth + 12)
                }
            }

            if model.hotkeysEnabled {
                PreferencesCard(
                    title: "Profiles",
                    subtitle: "Set the full transcription route for every recording shortcut."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach($model.recordingProfiles) { $profile in
                            recordingProfileEditor(profile: $profile)
                        }

                        HStack(spacing: 8) {
                            Button("Add Recording Shortcut") {
                                model.addRecordingProfile()
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Text("\(model.recordingProfiles.count) configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.hotkeysEnabled, model.hotkeyPreset == .manual {
                PreferencesCard(
                    title: "Control Shortcuts",
                    subtitle: "Format: cmd+shift+r or fn+ctrl. Leave empty to unbind."
                ) {
                    manualHotkeyEditor(
                        title: "Retry transcription",
                        placeholder: "fn+ctrl+r",
                        field: .retry,
                        text: $model.manualRetryHotkeyText
                    )

                    manualHotkeyEditor(
                        title: "Cancel recording",
                        placeholder: "fn+ctrl+escape",
                        field: .cancel,
                        text: $model.manualCancelHotkeyText
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func recordingProfileEditor(profile: Binding<EditableRecordingProfile>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                profileField("Name") {
                    TextField("Default", text: profile.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 150)
                }

                profileField("Shortcut") {
                    TextField("ctrl+shift+1", text: profile.hotkeyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 150)
                }

                profileField("Language") {
                    TextField("auto, en, no...", text: profile.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110)
                }

                Spacer(minLength: 8)

                Button("Remove", role: .destructive) {
                    model.removeRecordingProfile(profile.wrappedValue.id)
                }
                .buttonStyle(.bordered)
                .disabled(model.recordingProfiles.count <= 1)
            }

            HStack(alignment: .top, spacing: 12) {
                profileField("Primary") {
                    Picker("", selection: profile.provider) {
                        ForEach(ProviderKind.allCases, id: \.self) { provider in
                            Text(providerLabel(provider)).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 160)
                }

                profileField("Primary Model") {
                    TextField(model.profileModelPlaceholder(for: profile.wrappedValue.provider), text: profile.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 260)
                }

                profileField("Fallback") {
                    Picker("", selection: profile.fallbackProvider) {
                        ForEach(ProviderKind.allCases, id: \.self) { provider in
                            Text(providerLabel(provider)).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 160)
                }

                profileField("Fallback Model") {
                    TextField(model.profileModelPlaceholder(for: profile.wrappedValue.fallbackProvider), text: profile.fallbackModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 260)
                }
            }

            if let error = model.recordingProfileError(for: profile.wrappedValue) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .onChange(of: profile.wrappedValue.provider) { _, newProvider in
            model.updatePrimaryProvider(newProvider, for: profile.wrappedValue.id)
        }
        .onChange(of: profile.wrappedValue.fallbackProvider) { _, newProvider in
            model.updateFallbackProvider(newProvider, for: profile.wrappedValue.id)
        }
    }

    @ViewBuilder
    private func profileField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func settingRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: rowLabelWidth, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func manualHotkeyEditor(
        title: String,
        placeholder: String,
        field: PreferencesViewModel.ManualHotkeyField,
        text: Binding<String>
    ) -> some View {
        settingRow(title) {
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: 320)

                Button("Paste") {
                    model.pasteManualHotkey(field)
                }
                .buttonStyle(.bordered)
            }
        }

        if let error = model.manualHotkeyError(for: field) {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.leading, rowLabelWidth + 12)
        }
    }

    private func outputLabel(_ mode: OutputMode) -> String {
        switch mode {
        case .none:
            return "None"
        case .clipboard:
            return "Clipboard"
        case .pasteAtCursor:
            return "Paste at Cursor"
        case .clipboardAndPaste:
            return "Clipboard + Paste"
        }
    }

    private func providerLabel(_ provider: ProviderKind) -> String {
        switch provider {
        case .groq:
            return "Groq"
        case .openAI:
            return "OpenAI"
        case .whisperCpp:
            return "whisper.cpp"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    private func whisperCppRuntimeLabel(_ runtime: WhisperCppRuntime) -> String {
        switch runtime {
        case .auto:
            return "Auto (Server -> CLI)"
        case .server:
            return "Server"
        case .cli:
            return "CLI"
        }
    }

    private func whisperCppModelLabel(_ modelPath: String) -> String {
        let url = URL(fileURLWithPath: modelPath)
        let fileName = url.lastPathComponent
        if fileName.isEmpty || fileName == modelPath {
            return modelPath
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return "\(fileName) (\(parent))"
    }
}

@MainActor
final class PreferencesViewModel: ObservableObject {
    @Published var outputMode: OutputMode = .clipboardAndPaste
    @Published var recordingInteraction: RecordingInteractionMode = .toggle
    @Published var launchAtLoginEnabled = true
    @Published var language = "auto"
    @Published var vocabularyText = ""
    @Published var timeoutSeconds = 12
    @Published var groqModel = "whisper-large-v3"
    @Published var openAIModel = "gpt-4o-mini-transcribe"
    @Published var whisperCppModelPath = "ggml-large-v3.bin"
    @Published var whisperCppRuntime: WhisperCppRuntime = .auto
    @Published var elevenLabsModel = "scribe_v2"
    @Published var availableWhisperCppModels: [WhisperCppInstalledModel] = []
    @Published var isInstallingWhisperCppModel = false
    @Published var activeWhisperCppDownloadTitle: String?

    @Published var hotkeysEnabled = true
    @Published var hotkeyPreset: HotkeyPreset = .fnControl
    @Published var manualRetryHotkeyText = "fn+ctrl+r"
    @Published var manualCancelHotkeyText = "fn+ctrl+escape"
    @Published var recordingProfiles: [EditableRecordingProfile] = [
        EditableRecordingProfile(
            id: "default",
            name: "Default",
            hotkeyText: "fn+ctrl",
            provider: .groq,
            fallbackProvider: .openAI,
            model: "whisper-large-v3",
            fallbackModel: "gpt-4o-mini-transcribe",
            language: "auto"
        )
    ]

    @Published var groqAPIKeyInput = ""
    @Published var openAIAPIKeyInput = ""
    @Published var elevenLabsAPIKeyInput = ""
    @Published var hasGroqKey = false
    @Published var hasOpenAIKey = false
    @Published var hasElevenLabsKey = false
    @Published var isSaving = false

    @Published var statusMessage: String?
    @Published var statusIsError = false

    private let configurationManager: ConfigurationManager
    private let onSaved: @MainActor @Sendable () -> Void
    private var loadedSettings = AppSettings.default
    private let hotkeyFormatHint = "Invalid shortcut. Use modifiers like ctrl, shift, alt, cmd, or fn plus a key, e.g. ctrl+shift+alt+cmd+g."

    let whisperCppInstallPresets: [WhisperCppInstallPreset] = [
        WhisperCppInstallPreset(
            variant: "large-v3-q5_0",
            title: "Large v3 q5_0",
            detail: "balanced quality/speed",
            approxSizeGB: 1.1
        ),
        WhisperCppInstallPreset(
            variant: "large-v3",
            title: "Large v3 (full)",
            detail: "max quality",
            approxSizeGB: 3.1
        ),
        WhisperCppInstallPreset(
            variant: "large-v3-turbo-q5_0",
            title: "Large v3 turbo q5_0",
            detail: "fastest balanced",
            approxSizeGB: 1.1
        ),
        WhisperCppInstallPreset(
            variant: "large-v3-turbo",
            title: "Large v3 turbo",
            detail: "very fast",
            approxSizeGB: 1.6
        )
    ]

    init(
        configurationManager: ConfigurationManager,
        onSaved: @escaping @MainActor @Sendable () -> Void
    ) {
        self.configurationManager = configurationManager
        self.onSaved = onSaved
    }

    var availableHotkeyPresets: [HotkeyPreset] {
        HotkeyPreset.allCases
    }

    var hotkeySummary: String {
        do {
            let bindings = try hotkeysForSave()
            guard !bindings.isEmpty else {
                return "No shortcuts configured."
            }
            return bindings.map(describeHotkey).joined(separator: "  |  ")
        } catch let error as SettingsValidationErrorSet {
            return error.issues.map { "\($0.field): \($0.message)" }.joined(separator: " | ")
        } catch {
            return "Invalid hotkey configuration."
        }
    }

    var vocabularyHintCount: Int {
        parseVocabularyHints(vocabularyText).count
    }

    var hasInlineValidationErrors: Bool {
        if recordingProfiles.contains(where: { recordingProfileError(for: $0) != nil }) {
            return true
        }
        guard hotkeysEnabled, hotkeyPreset == .manual else {
            return false
        }
        return manualHotkeyError(for: .retry) != nil
            || manualHotkeyError(for: .cancel) != nil
    }

    var hasUnsavedChanges: Bool {
        let current = currentSnapshot()
        let loaded = snapshot(from: loadedSettings)
        let hasPendingAPIInput = !normalize(groqAPIKeyInput).isEmpty
            || !normalize(openAIAPIKeyInput).isEmpty
            || !normalize(elevenLabsAPIKeyInput).isEmpty
        return current != loaded || hasPendingAPIInput
    }

    var canSave: Bool {
        hasUnsavedChanges && !isSaving && !hasInlineValidationErrors
    }

    enum ManualHotkeyField {
        case retry
        case cancel

        var actionID: String {
            switch self {
            case .retry: return "retry"
            case .cancel: return "cancel"
            }
        }

        var fieldPath: String {
            switch self {
            case .retry: return "hotkeys.retry"
            case .cancel: return "hotkeys.cancel"
            }
        }
    }

    func clearVocabulary() {
        vocabularyText = ""
    }

    func refreshWhisperCppModels() {
        availableWhisperCppModels = discoveredWhisperCppModels(currentSelection: normalize(whisperCppModelPath))
    }

    func installWhisperCppModel(_ preset: WhisperCppInstallPreset) async {
        guard !isInstallingWhisperCppModel else {
            return
        }

        isInstallingWhisperCppModel = true
        defer { isInstallingWhisperCppModel = false }

        let fileManager = FileManager.default
        let cacheDirectory = whisperCppModelCacheDirectory()
        let destinationURL = cacheDirectory.appendingPathComponent(preset.fileName)

        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                whisperCppModelPath = destinationURL.path
                refreshWhisperCppModels()
                let sizeLabel = fileSizeLabel(at: destinationURL.path) ?? "unknown size"
                statusMessage = "\(preset.title) already installed (\(sizeLabel))."
                statusIsError = false
                return
            }

            statusMessage = "Downloading \(preset.title)..."
            statusIsError = false
            activeWhisperCppDownloadTitle = preset.title

            let request = URLRequest(url: preset.downloadURL, timeoutInterval: 60 * 30)
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(
                    domain: "PreferencesViewModel",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

            whisperCppModelPath = destinationURL.path
            refreshWhisperCppModels()
            let sizeLabel = fileSizeLabel(at: destinationURL.path) ?? "unknown size"
            statusMessage = "Installed \(preset.title) (\(sizeLabel))."
            statusIsError = false
            activeWhisperCppDownloadTitle = nil
        } catch {
            let reason: String
            if let urlError = error as? URLError {
                reason = "network error (\(urlError.code.rawValue)): \(urlError.localizedDescription)"
            } else {
                reason = error.localizedDescription
            }
            statusMessage = "Failed to download \(preset.title): \(reason)"
            statusIsError = true
            activeWhisperCppDownloadTitle = nil
        }
    }

    func deleteWhisperCppModel(_ modelPath: String) {
        let normalized = (modelPath as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: normalized) else {
            refreshWhisperCppModels()
            statusMessage = "Model file not found: \(normalized)"
            statusIsError = true
            return
        }

        do {
            try fileManager.removeItem(atPath: normalized)
            refreshWhisperCppModels()

            if normalize(whisperCppModelPath) == normalize(normalized) {
                if let replacement = availableWhisperCppModels.first?.path {
                    whisperCppModelPath = replacement
                    statusMessage = "Deleted model and switched to \(URL(fileURLWithPath: replacement).lastPathComponent)."
                } else {
                    whisperCppModelPath = ProviderConfiguration.defaultValue.whisperCppModelPath
                    statusMessage = "Deleted model. No local models remain."
                }
            } else {
                statusMessage = "Deleted \(URL(fileURLWithPath: normalized).lastPathComponent)."
            }
            statusIsError = false
        } catch {
            statusMessage = "Failed to delete model: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    func clearAPIKeyInput(_ provider: ProviderKind) {
        switch provider {
        case .groq:
            groqAPIKeyInput = ""
        case .openAI:
            openAIAPIKeyInput = ""
        case .elevenLabs:
            elevenLabsAPIKeyInput = ""
        case .whisperCpp:
            break
        }
    }

    func manualHotkeyError(for field: ManualHotkeyField) -> String? {
        let rawValue: String
        switch field {
        case .retry:
            rawValue = manualRetryHotkeyText
        case .cancel:
            rawValue = manualCancelHotkeyText
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard HotkeyCodec.parse(trimmed, actionID: field.actionID) != nil else {
            return hotkeyFormatHint
        }
        return nil
    }

    func pasteAPIKey(_ provider: ProviderKind) {
        guard let value = clipboardString(), !value.isEmpty else {
            return
        }

        switch provider {
        case .groq:
            groqAPIKeyInput = value
        case .openAI:
            openAIAPIKeyInput = value
        case .elevenLabs:
            elevenLabsAPIKeyInput = value
        case .whisperCpp:
            break
        }
    }

    func pasteManualHotkey(_ field: ManualHotkeyField) {
        guard let value = clipboardString(), !value.isEmpty else {
            return
        }

        switch field {
        case .retry:
            manualRetryHotkeyText = value
        case .cancel:
            manualCancelHotkeyText = value
        }
    }

    func addRecordingProfile() {
        let index = recordingProfiles.count + 1
        let id = uniqueProfileID(base: "profile-\(index)")
        recordingProfiles.append(
            EditableRecordingProfile(
                id: id,
                name: "Profile \(index)",
                hotkeyText: "",
                provider: .elevenLabs,
                fallbackProvider: .openAI,
                model: ProviderConfiguration.defaultValue.elevenLabsModel,
                fallbackModel: ProviderConfiguration.defaultValue.openAIModel,
                language: "auto"
            )
        )
    }

    func removeRecordingProfile(_ id: String) {
        guard recordingProfiles.count > 1 else {
            return
        }
        recordingProfiles.removeAll { $0.id == id }
    }

    func profileModelPlaceholder(for provider: ProviderKind) -> String {
        defaultModel(for: provider)
    }

    func updatePrimaryProvider(_ provider: ProviderKind, for profileID: String) {
        guard let index = recordingProfiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        recordingProfiles[index].model = defaultModel(for: provider)
    }

    func updateFallbackProvider(_ provider: ProviderKind, for profileID: String) {
        guard let index = recordingProfiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        recordingProfiles[index].fallbackModel = defaultModel(for: provider)
    }

    func defaultModel(for provider: ProviderKind) -> String {
        switch provider {
        case .groq:
            return normalize(groqModel).isEmpty ? ProviderConfiguration.defaultValue.groqModel : normalize(groqModel)
        case .openAI:
            return normalize(openAIModel).isEmpty ? ProviderConfiguration.defaultValue.openAIModel : normalize(openAIModel)
        case .whisperCpp:
            return normalize(whisperCppModelPath).isEmpty ? ProviderConfiguration.defaultValue.whisperCppModelPath : normalize(whisperCppModelPath)
        case .elevenLabs:
            return normalize(elevenLabsModel).isEmpty ? ProviderConfiguration.defaultValue.elevenLabsModel : normalize(elevenLabsModel)
        }
    }

    func recordingProfileError(for profile: EditableRecordingProfile) -> String? {
        if normalize(profile.name).isEmpty {
            return "Name cannot be empty."
        }
        if normalize(profile.model).isEmpty {
            return "Primary model cannot be empty."
        }
        if normalize(profile.fallbackModel).isEmpty {
            return "Fallback model cannot be empty."
        }
        if normalize(profile.language).isEmpty {
            return "Language cannot be empty."
        }
        if profile.provider == profile.fallbackProvider {
            return "Provider and fallback must be different."
        }
        if normalize(profile.hotkeyText).isEmpty {
            return "Shortcut cannot be empty."
        }
        let actionID = "recording.\(profile.id)"
        guard HotkeyCodec.parse(profile.hotkeyText, actionID: actionID) != nil else {
            return hotkeyFormatHint
        }
        let matchingHotkeys = recordingProfiles.filter {
            normalizeHotkey($0.hotkeyText) == normalizeHotkey(profile.hotkeyText)
        }
        if matchingHotkeys.count > 1 {
            return "Shortcut is already used by another recording profile."
        }
        return nil
    }

    func pasteVocabulary() {
        guard let value = clipboardString(), !value.isEmpty else {
            return
        }

        if vocabularyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vocabularyText = value
            return
        }
        vocabularyText += "\n\(value)"
    }

    func clearStoredAPIKey(_ provider: ProviderKind) async {
        do {
            try await configurationManager.clearAPIKey(for: provider)
            switch provider {
            case .groq:
                hasGroqKey = false
                groqAPIKeyInput = ""
                statusMessage = "Groq key removed."
            case .openAI:
                hasOpenAIKey = false
                openAIAPIKeyInput = ""
                statusMessage = "OpenAI key removed."
            case .elevenLabs:
                hasElevenLabsKey = false
                elevenLabsAPIKeyInput = ""
                statusMessage = "ElevenLabs key removed."
            case .whisperCpp:
                break
            }
            statusIsError = false
        } catch {
            statusMessage = "Failed to remove stored key: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    func load() async {
        do {
            let settings = try await configurationManager.loadSettings()
            loadedSettings = settings
            apply(settings: settings)

            groqAPIKeyInput = ""
            openAIAPIKeyInput = ""
            elevenLabsAPIKeyInput = ""
            hasGroqKey = (try await configurationManager.loadAPIKey(for: .groq)) != nil
            hasOpenAIKey = (try await configurationManager.loadAPIKey(for: .openAI)) != nil
            hasElevenLabsKey = (try await configurationManager.loadAPIKey(for: .elevenLabs)) != nil
            refreshWhisperCppModels()

            statusMessage = nil
            statusIsError = false
        } catch {
            statusMessage = "Failed to load settings"
            statusIsError = true
        }
    }

    func applyDefaults() {
        apply(settings: .default)
        groqAPIKeyInput = ""
        openAIAPIKeyInput = ""
        elevenLabsAPIKeyInput = ""
        refreshWhisperCppModels()
        statusMessage = "Defaults loaded. Save to apply."
        statusIsError = false
    }

    func discardChanges() {
        apply(settings: loadedSettings)
        groqAPIKeyInput = ""
        openAIAPIKeyInput = ""
        elevenLabsAPIKeyInput = ""
        refreshWhisperCppModels()
        statusMessage = "Changes discarded."
        statusIsError = false
    }

    func save() async {
        guard !isSaving else {
            return
        }

        if !hasUnsavedChanges {
            statusMessage = "No changes to save."
            statusIsError = false
            return
        }

        if hotkeysEnabled {
            if let profileError = recordingProfiles.compactMap(recordingProfileError).first {
                statusMessage = profileError
                statusIsError = true
                return
            }
        }

        if hotkeysEnabled, hotkeyPreset == .manual {
            if let hotkeyError = manualHotkeyError(for: .retry)
                ?? manualHotkeyError(for: .cancel)
            {
                statusMessage = hotkeyError
                statusIsError = true
                return
            }
        }

        isSaving = true
        defer { isSaving = false }

        loadedSettings.outputMode = outputMode
        loadedSettings.recordingInteraction = recordingInteraction
        loadedSettings.launchAtLoginEnabled = launchAtLoginEnabled
        loadedSettings.language = normalize(language)
        loadedSettings.vocabularyHints = parseVocabularyHints(vocabularyText)

        loadedSettings.provider.timeoutSeconds = timeoutSeconds
        loadedSettings.provider.groqModel = normalize(groqModel)
        loadedSettings.provider.openAIModel = normalize(openAIModel)
        loadedSettings.provider.whisperCppModelPath = normalize(whisperCppModelPath)
        loadedSettings.provider.whisperCppRuntime = whisperCppRuntime
        loadedSettings.provider.elevenLabsModel = normalize(elevenLabsModel)

        do {
            let savedProfiles = try recordingProfilesForSave()
            loadedSettings.recordingProfiles = savedProfiles
            if let firstProfile = savedProfiles.first {
                loadedSettings.provider.primary = firstProfile.provider
                loadedSettings.provider.fallback = firstProfile.fallbackProvider
            }
            loadedSettings.hotkeys = try hotkeysForSave()
            try await configurationManager.saveSettings(loadedSettings)

            let groqTrimmed = normalize(groqAPIKeyInput)
            if !groqTrimmed.isEmpty {
                try await configurationManager.saveAPIKey(groqTrimmed, for: .groq)
                groqAPIKeyInput = ""
            }

            let openAITrimmed = normalize(openAIAPIKeyInput)
            if !openAITrimmed.isEmpty {
                try await configurationManager.saveAPIKey(openAITrimmed, for: .openAI)
                openAIAPIKeyInput = ""
            }

            let elevenLabsTrimmed = normalize(elevenLabsAPIKeyInput)
            if !elevenLabsTrimmed.isEmpty {
                try await configurationManager.saveAPIKey(elevenLabsTrimmed, for: .elevenLabs)
                elevenLabsAPIKeyInput = ""
            }

            hasGroqKey = (try await configurationManager.loadAPIKey(for: .groq)) != nil
            hasOpenAIKey = (try await configurationManager.loadAPIKey(for: .openAI)) != nil
            hasElevenLabsKey = (try await configurationManager.loadAPIKey(for: .elevenLabs)) != nil

            statusMessage = "Saved and applied."
            statusIsError = false
            onSaved()
        } catch let error as SettingsValidationErrorSet {
            statusMessage = error.issues.map { "\($0.field): \($0.message)" }.joined(separator: " | ")
            statusIsError = true
        } catch {
            statusMessage = "Failed to save settings: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    private func hotkeysForSave() throws -> [HotkeyBinding] {
        guard hotkeysEnabled else {
            return []
        }

        let profileHotkeys = try recordingProfilesForSave().map(\.hotkey)
        let controlHotkeys: [HotkeyBinding]
        switch hotkeyPreset {
        case .fnControl:
            controlHotkeys = [
                HotkeyBinding(actionID: "retry", keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .function]),
                HotkeyBinding(actionID: "cancel", keyCode: UInt32(kVK_Escape), modifiers: [.control, .function])
            ]
        case .ctrlShift:
            controlHotkeys = [
                HotkeyBinding(actionID: "retry", keyCode: UInt32(kVK_ANSI_2), modifiers: [.control, .shift]),
                HotkeyBinding(actionID: "cancel", keyCode: UInt32(kVK_ANSI_3), modifiers: [.control, .shift])
            ]
        case .manual:
            controlHotkeys = try parseManualControlHotkeys()
        }
        return profileHotkeys + controlHotkeys
    }

    private func parseManualControlHotkeys() throws -> [HotkeyBinding] {
        var bindings: [HotkeyBinding] = []
        var issues: [SettingsValidationIssue] = []

        let rows: [(field: ManualHotkeyField, rawValue: String)] = [
            (.retry, manualRetryHotkeyText),
            (.cancel, manualCancelHotkeyText)
        ]

        for row in rows {
            let trimmed = row.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            guard let parsed = HotkeyCodec.parse(trimmed, actionID: row.field.actionID) else {
                issues.append(
                    SettingsValidationIssue(
                        field: row.field.fieldPath,
                        message: hotkeyFormatHint
                    )
                )
                continue
            }

            bindings.append(parsed)
        }

        if !issues.isEmpty {
            throw SettingsValidationErrorSet(issues: issues)
        }

        return bindings
    }

    private func recordingProfilesForSave() throws -> [RecordingShortcutProfile] {
        var issues: [SettingsValidationIssue] = []
        var seenIDs = Set<String>()

        let profiles = recordingProfiles.map { editable -> RecordingShortcutProfile? in
            let id = normalizeProfileID(editable.id)
            let actionID = "recording.\(id)"
            if id.isEmpty || seenIDs.contains(id) {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(editable.id)", message: "Profile id must be unique"))
                return nil
            }
            seenIDs.insert(id)

            guard let hotkey = HotkeyCodec.parse(editable.hotkeyText, actionID: actionID) else {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(id).hotkey", message: hotkeyFormatHint))
                return nil
            }
            if editable.provider == editable.fallbackProvider {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(id).fallbackProvider", message: "Provider and fallback must differ"))
                return nil
            }
            if normalize(editable.model).isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(id).model", message: "Primary model must not be empty"))
                return nil
            }
            if normalize(editable.fallbackModel).isEmpty {
                issues.append(SettingsValidationIssue(field: "recordingProfiles.\(id).fallbackModel", message: "Fallback model must not be empty"))
                return nil
            }

            return RecordingShortcutProfile(
                id: id,
                name: normalize(editable.name),
                hotkey: hotkey,
                provider: editable.provider,
                fallbackProvider: editable.fallbackProvider,
                model: normalize(editable.model),
                fallbackModel: normalize(editable.fallbackModel),
                language: normalize(editable.language)
            )
        }.compactMap { $0 }

        if !issues.isEmpty {
            throw SettingsValidationErrorSet(issues: issues)
        }
        return profiles
    }

    private func detectPreset(hotkeys: [HotkeyBinding]) -> HotkeyPreset {
        let fnControl: [HotkeyBinding] = [
            HotkeyBinding(actionID: "retry", keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .function]),
            HotkeyBinding(actionID: "cancel", keyCode: UInt32(kVK_Escape), modifiers: [.control, .function])
        ]
        let ctrlShift: [HotkeyBinding] = [
            HotkeyBinding(actionID: "retry", keyCode: UInt32(kVK_ANSI_2), modifiers: [.control, .shift]),
            HotkeyBinding(actionID: "cancel", keyCode: UInt32(kVK_ANSI_3), modifiers: [.control, .shift])
        ]
        let controlHotkeys = hotkeys.filter { $0.actionID == "retry" || $0.actionID == "cancel" }

        if controlHotkeys == fnControl {
            return .fnControl
        }
        if controlHotkeys == ctrlShift {
            return .ctrlShift
        }
        return .manual
    }

    private func loadManualHotkeys(from hotkeys: [HotkeyBinding]) {
        let byAction = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.actionID, $0) })
        manualRetryHotkeyText = byAction["retry"].flatMap(HotkeyCodec.render) ?? ""
        manualCancelHotkeyText = byAction["cancel"].flatMap(HotkeyCodec.render) ?? ""
    }

    private func describeHotkey(_ binding: HotkeyBinding) -> String {
        let actionName: String
        switch binding.actionID {
        case "toggle": actionName = "Toggle"
        case "retry": actionName = "Retry"
        case "cancel": actionName = "Cancel"
        default:
            if let profile = recordingProfiles.first(where: { "recording.\($0.id)" == binding.actionID }) {
                actionName = profile.name
            } else {
                actionName = binding.actionID
            }
        }
        return "\(actionName): \(HotkeyCodec.displayString(binding))"
    }

    private func parseVocabularyHints(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func discoveredWhisperCppModels(currentSelection: String) -> [WhisperCppInstalledModel] {
        let fileManager = FileManager.default
        let directories = [
            "/opt/homebrew/opt/whisper-cpp/share/whisper/models",
            "/usr/local/opt/whisper-cpp/share/whisper/models",
            "/opt/homebrew/share/whisper/models",
            "/usr/local/share/whisper/models",
            "~/.cache/whisper"
        ].map { ($0 as NSString).expandingTildeInPath }

        var models: [String: Int64] = [:]
        for directory in directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            let entries = (try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries where entry.pathExtension.lowercased() == "bin" {
                let path = entry.path
                let size = fileSizeBytes(at: path) ?? 0
                if models[path] == nil {
                    models[path] = size
                }
            }
        }

        let expandedSelection = (currentSelection as NSString).expandingTildeInPath
        if !expandedSelection.isEmpty, fileManager.fileExists(atPath: expandedSelection) {
            models[expandedSelection] = fileSizeBytes(at: expandedSelection) ?? 0
        }

        let sortedPaths = models.keys.sorted { lhs, rhs in
            let leftName = URL(fileURLWithPath: lhs).lastPathComponent
            let rightName = URL(fileURLWithPath: rhs).lastPathComponent
            if leftName == rightName {
                return lhs < rhs
            }
            return leftName < rightName
        }

        return sortedPaths.map { path in
            WhisperCppInstalledModel(path: path, sizeBytes: models[path] ?? 0)
        }
    }

    private func whisperCppModelCacheDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper", isDirectory: true)
    }

    private func fileSizeBytes(at path: String) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func fileSizeLabel(at path: String) -> String? {
        guard let bytes = fileSizeBytes(at: path) else {
            return nil
        }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
    }

    private func apply(settings: AppSettings) {
        outputMode = settings.outputMode
        recordingInteraction = settings.recordingInteraction
        launchAtLoginEnabled = settings.launchAtLoginEnabled
        language = settings.language
        vocabularyText = settings.vocabularyHints.joined(separator: "\n")
        timeoutSeconds = settings.provider.timeoutSeconds
        groqModel = settings.provider.groqModel
        openAIModel = settings.provider.openAIModel
        whisperCppModelPath = settings.provider.whisperCppModelPath
        whisperCppRuntime = settings.provider.whisperCppRuntime
        elevenLabsModel = settings.provider.elevenLabsModel
        availableWhisperCppModels = discoveredWhisperCppModels(currentSelection: normalize(settings.provider.whisperCppModelPath))

        hotkeysEnabled = !settings.hotkeys.isEmpty
        hotkeyPreset = detectPreset(hotkeys: settings.hotkeys)
        loadManualHotkeys(from: settings.hotkeys)
        recordingProfiles = editableProfiles(from: settings)
    }

    private struct EditorSnapshot: Equatable {
        let outputMode: OutputMode
        let recordingInteraction: RecordingInteractionMode
        let launchAtLoginEnabled: Bool
        let language: String
        let vocabularyHints: [String]
        let timeoutSeconds: Int
        let groqModel: String
        let openAIModel: String
        let whisperCppModelPath: String
        let whisperCppRuntime: WhisperCppRuntime
        let elevenLabsModel: String
        let hotkeysEnabled: Bool
        let hotkeyPreset: HotkeyPreset
        let manualRetryHotkeyText: String
        let manualCancelHotkeyText: String
        let recordingProfiles: [EditableRecordingProfile]
    }

    private func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(
            outputMode: outputMode,
            recordingInteraction: recordingInteraction,
            launchAtLoginEnabled: launchAtLoginEnabled,
            language: normalize(language),
            vocabularyHints: parseVocabularyHints(vocabularyText),
            timeoutSeconds: timeoutSeconds,
            groqModel: normalize(groqModel),
            openAIModel: normalize(openAIModel),
            whisperCppModelPath: normalize(whisperCppModelPath),
            whisperCppRuntime: whisperCppRuntime,
            elevenLabsModel: normalize(elevenLabsModel),
            hotkeysEnabled: hotkeysEnabled,
            hotkeyPreset: hotkeyPreset,
            manualRetryHotkeyText: normalizeHotkey(manualRetryHotkeyText),
            manualCancelHotkeyText: normalizeHotkey(manualCancelHotkeyText),
            recordingProfiles: normalizedEditableProfiles(recordingProfiles)
        )
    }

    private func snapshot(from settings: AppSettings) -> EditorSnapshot {
        let byAction = Dictionary(uniqueKeysWithValues: settings.hotkeys.map { ($0.actionID, $0) })
        return EditorSnapshot(
            outputMode: settings.outputMode,
            recordingInteraction: settings.recordingInteraction,
            launchAtLoginEnabled: settings.launchAtLoginEnabled,
            language: normalize(settings.language),
            vocabularyHints: settings.vocabularyHints.map(normalize),
            timeoutSeconds: settings.provider.timeoutSeconds,
            groqModel: normalize(settings.provider.groqModel),
            openAIModel: normalize(settings.provider.openAIModel),
            whisperCppModelPath: normalize(settings.provider.whisperCppModelPath),
            whisperCppRuntime: settings.provider.whisperCppRuntime,
            elevenLabsModel: normalize(settings.provider.elevenLabsModel),
            hotkeysEnabled: !settings.hotkeys.isEmpty,
            hotkeyPreset: detectPreset(hotkeys: settings.hotkeys),
            manualRetryHotkeyText: normalizeHotkey(byAction["retry"].flatMap(HotkeyCodec.render) ?? ""),
            manualCancelHotkeyText: normalizeHotkey(byAction["cancel"].flatMap(HotkeyCodec.render) ?? ""),
            recordingProfiles: normalizedEditableProfiles(editableProfiles(from: settings))
        )
    }

    private func editableProfiles(from settings: AppSettings) -> [EditableRecordingProfile] {
        let profiles = settings.recordingProfiles.isEmpty ? [RecordingShortcutProfile.defaultProfile] : settings.recordingProfiles
        return profiles.map { profile in
            EditableRecordingProfile(
                id: profile.id,
                name: profile.name,
                hotkeyText: HotkeyCodec.render(profile.hotkey) ?? "",
                provider: profile.provider,
                fallbackProvider: profile.fallbackProvider,
                model: profile.model,
                fallbackModel: profile.fallbackModel,
                language: profile.language
            )
        }
    }

    private func normalizedEditableProfiles(_ profiles: [EditableRecordingProfile]) -> [EditableRecordingProfile] {
        profiles.map {
            EditableRecordingProfile(
                id: normalizeProfileID($0.id),
                name: normalize($0.name),
                hotkeyText: normalizeHotkey($0.hotkeyText),
                provider: $0.provider,
                fallbackProvider: $0.fallbackProvider,
                model: normalize($0.model),
                fallbackModel: normalize($0.fallbackModel),
                language: normalize($0.language)
            )
        }
    }

    private func normalizeProfileID(_ value: String) -> String {
        let allowed = normalize(value)
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" {
                    return character
                }
                return "-"
            }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func uniqueProfileID(base: String) -> String {
        let normalizedBase = normalizeProfileID(base).isEmpty ? "profile" : normalizeProfileID(base)
        var candidate = normalizedBase
        var index = 2
        let existing = Set(recordingProfiles.map { normalizeProfileID($0.id) })
        while existing.contains(candidate) {
            candidate = "\(normalizedBase)-\(index)"
            index += 1
        }
        return candidate
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeHotkey(_ value: String) -> String {
        normalize(value).lowercased()
    }

    private func clipboardString() -> String? {
        NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
