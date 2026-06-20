import AppKit
import SwiftUI
import QuedoCore

/// History window showing recent transcription sessions.
struct HistoryView: View {
    @StateObject private var model: HistoryViewModel

    init(
        historyStore: HistoryStore,
        transcriptionPipeline: TranscriptionPipeline,
        configurationManager: ConfigurationManager
    ) {
        _model = StateObject(wrappedValue: HistoryViewModel(
            historyStore: historyStore,
            transcriptionPipeline: transcriptionPipeline,
            configurationManager: configurationManager
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Sessions")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task {
                        await model.load(reset: true)
                    }
                }
            }

            List(model.sessions, id: \.sessionID) { session in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(session.transcriptPreview)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Copy") {
                            Task {
                                await model.copyTranscript(sessionID: session.sessionID)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("Play") {
                            Task {
                                await model.playAudio(sessionID: session.sessionID)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        Text(session.createdAt.formatted(date: .numeric, time: .shortened))
                        Text("•")
                        Text("\(session.durationMS) ms")
                        Text("•")
                        Text(session.providerUsed.rawValue)
                        Text("•")
                        Text(session.status.rawValue)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField("Language (e.g. en, no, auto)", text: model.retranscribeLanguageBinding(for: session.sessionID))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)

                        Button(model.retranscribingSessionID == session.sessionID ? "Transcribing..." : "Re-transcribe") {
                            Task {
                                await model.retranscribe(sessionID: session.sessionID)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.retranscribingSessionID != nil)
                    }
                }
                .padding(.vertical, 4)
                .onAppear {
                    Task {
                        await model.loadMoreIfNeeded(visibleSessionID: session.sessionID)
                    }
                }
            }

            if model.hasMore {
                HStack {
                    Spacer()
                    Button(model.isLoadingMore ? "Loading..." : "Show More") {
                        Task {
                            await model.loadMore()
                        }
                    }
                    .disabled(model.isLoadingMore)
                    Spacer()
                }
            }

            if let status = model.statusMessage {
                Text(status)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
        .task {
            await model.load(reset: true)
        }
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var sessions: [HistorySessionSummary] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var hasMore = false
    @Published var isLoadingMore = false
    @Published var retranscribingSessionID: UUID?
    @Published var retranscribeLanguages: [UUID: String] = [:]

    private let historyStore: HistoryStore
    private let transcriptionPipeline: TranscriptionPipeline
    private let configurationManager: ConfigurationManager
    private let pageSize = 100
    private var currentLimit = 100
    private var playbackSound: NSSound?

    init(
        historyStore: HistoryStore,
        transcriptionPipeline: TranscriptionPipeline,
        configurationManager: ConfigurationManager
    ) {
        self.historyStore = historyStore
        self.transcriptionPipeline = transcriptionPipeline
        self.configurationManager = configurationManager
    }

    func retranscribeLanguageBinding(for sessionID: UUID) -> Binding<String> {
        Binding(
            get: { self.retranscribeLanguages[sessionID, default: "auto"] },
            set: { self.retranscribeLanguages[sessionID] = $0 }
        )
    }

    func load(reset: Bool) async {
        if reset {
            currentLimit = pageSize
        }
        if !reset {
            isLoadingMore = true
        }
        defer {
            if !reset {
                isLoadingMore = false
            }
        }

        do {
            let loaded = try await historyStore.listSessions(limit: currentLimit + 1)
            hasMore = loaded.count > currentLimit
            sessions = Array(loaded.prefix(currentLimit))
            errorMessage = nil
            if reset {
                statusMessage = nil
            }
        } catch {
            errorMessage = "Failed to load history"
            hasMore = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else {
            return
        }

        currentLimit += pageSize
        await load(reset: false)
    }

    func loadMoreIfNeeded(visibleSessionID: UUID) async {
        guard
            hasMore,
            !isLoadingMore,
            sessions.last?.sessionID == visibleSessionID
        else {
            return
        }

        await loadMore()
    }

    func copyTranscript(sessionID: UUID) async {
        do {
            guard let transcript = try await historyStore.transcriptText(sessionID: sessionID) else {
                statusMessage = "No transcript found"
                return
            }

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                statusMessage = "Transcript is empty"
                return
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            statusMessage = "Transcript copied"
            errorMessage = nil
        } catch {
            errorMessage = "Failed to copy transcript"
        }
    }

    func playAudio(sessionID: UUID) async {
        do {
            guard let audioURL = try await historyStore.primaryAudioFileURL(sessionID: sessionID) else {
                errorMessage = "No audio file found for this session"
                return
            }

            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                errorMessage = "Audio file missing from disk"
                return
            }

            playbackSound?.stop()
            guard let sound = NSSound(contentsOf: audioURL, byReference: true) else {
                errorMessage = "Failed to open audio file"
                return
            }

            playbackSound = sound
            statusMessage = "Playing recording"
            errorMessage = nil

            if !sound.play() {
                playbackSound = nil
                errorMessage = "Failed to start playback"
                statusMessage = nil
            }
        } catch {
            errorMessage = "Failed to play audio"
            statusMessage = nil
            playbackSound = nil
        }
    }

    func retranscribe(sessionID: UUID) async {
        guard retranscribingSessionID == nil else { return }

        do {
            guard let audioURL = try await historyStore.primaryAudioFileURL(sessionID: sessionID) else {
                errorMessage = "No audio file found for this session"
                return
            }

            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                errorMessage = "Audio file missing from disk"
                return
            }

            guard let details = try await historyStore.sessionDetails(sessionID: sessionID) else {
                errorMessage = "History session metadata missing"
                return
            }

            retranscribingSessionID = sessionID
            statusMessage = "Re-transcribing..."
            errorMessage = nil

            let language = retranscribeLanguages[sessionID, default: "auto"]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var settings = try await configurationManager.loadSettings()
            settings.provider.primary = details.providerPrimary
            settings.language = language.isEmpty ? details.language : language

            let result = try await transcriptionPipeline.transcribe(
                audioFileURL: audioURL,
                settings: settings
            )

            let record = SessionRecord(
                sessionID: sessionID,
                createdAt: details.createdAt,
                durationMS: details.durationMS,
                providerPrimary: details.providerPrimary,
                providerUsed: result.providerUsed,
                language: settings.language,
                outputMode: details.outputMode,
                status: .success,
                transcript: result.text,
                audioPath: audioURL
            )
            try await historyStore.saveSession(record)
            statusMessage = "Re-transcription complete"
            retranscribingSessionID = nil
            await load(reset: true)
        } catch {
            errorMessage = "Re-transcription failed: \(error.localizedDescription)"
            statusMessage = nil
            retranscribingSessionID = nil
        }
    }
}
