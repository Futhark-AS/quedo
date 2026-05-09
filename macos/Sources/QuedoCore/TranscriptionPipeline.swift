import AVFoundation
import Foundation

/// Errors returned by the transcription pipeline.
public enum TranscriptionPipelineError: Error, Sendable {
    /// No provider instance for requested kind.
    case providerUnavailable(ProviderKind)
    /// Both primary and fallback providers failed.
    case retryAvailable(primary: ProviderKind, fallback: ProviderKind)
    /// Audio file could not be chunked.
    case chunkingFailed
}

/// Finalized pipeline output.
public struct TranscriptionPipelineResult: Sendable {
    /// Final transcript text.
    public let text: String
    /// Provider used for final transcript.
    public let providerUsed: ProviderKind
    /// Indicates fallback path was used.
    public let fallbackUsed: Bool

    /// Creates a pipeline result.
    public init(text: String, providerUsed: ProviderKind, fallbackUsed: Bool) {
        self.text = text
        self.providerUsed = providerUsed
        self.fallbackUsed = fallbackUsed
    }
}

/// Per-request provider model overrides.
public struct TranscriptionModelOverrides: Sendable {
    /// Primary provider model override.
    public let primaryModel: String?
    /// Fallback provider model override.
    public let fallbackModel: String?

    /// Creates model overrides.
    public init(primaryModel: String? = nil, fallbackModel: String? = nil) {
        self.primaryModel = primaryModel
        self.fallbackModel = fallbackModel
    }
}

/// Orchestrates provider selection, retries, fallback, chunking, and cleanup.
public actor TranscriptionPipeline {
    private let providers: [ProviderKind: any TranscriptionProvider]
    private var fallbackStickyUntil: Date?
    private var primaryProbeTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    private let requestTimeoutSeconds: Int
    private let chunkDurationSeconds: Double = 5 * 60

    /// Creates a transcription pipeline with registered providers.
    public init(providers: [any TranscriptionProvider], requestTimeoutSeconds: Int = 12) {
        var table: [ProviderKind: any TranscriptionProvider] = [:]
        for provider in providers {
            table[provider.kind] = provider
        }
        self.providers = table
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    /// Performs transcription with primary retry and fallback policy.
    public func transcribe(
        audioFileURL: URL,
        settings: AppSettings,
        modelOverrides: TranscriptionModelOverrides = TranscriptionModelOverrides(),
        replacements: [String: String] = [:]
    ) async throws -> TranscriptionPipelineResult {
        let now = Date()
        let fallbackIsSticky = fallbackStickyUntil.map { now < $0 } ?? false

        let preferredPrimary = fallbackIsSticky ? settings.provider.fallback : settings.provider.primary
        let preferredFallback = fallbackIsSticky ? settings.provider.primary : settings.provider.fallback

        let preparedChunks = try prepareSourceChunks(audioFileURL)
        var temporaryFiles = preparedChunks.temporaryFiles
        var flacUploadChunks: [URL]?
        defer {
            cleanupTemporaryFiles(temporaryFiles)
        }

        func chunksForProvider(_ provider: any TranscriptionProvider) throws -> [URL] {
            guard provider.requiresFLACUpload else {
                return preparedChunks.chunkFiles
            }

            if let flacUploadChunks {
                return flacUploadChunks
            }

            var converted: [URL] = []
            for chunk in preparedChunks.chunkFiles {
                if chunk.pathExtension.lowercased() == "flac" {
                    converted.append(chunk)
                    continue
                }

                let transcoded = try transcodeToFLAC(chunk)
                converted.append(transcoded)
                temporaryFiles.append(transcoded)
            }
            flacUploadChunks = converted
            return converted
        }

        let primary = try provider(for: preferredPrimary)
        let fallback = try provider(for: preferredFallback)

        do {
            let primaryChunks = try chunksForProvider(primary)
            let text = try await runChunks(
                chunks: primaryChunks,
                with: primary,
                model: modelOverrides.primaryModel ?? model(for: preferredPrimary, settings: settings),
                language: settings.language,
                vocabularyHints: settings.vocabularyHints
            )
            let cleaned = cleanup(text: text, replacements: replacements)
            return TranscriptionPipelineResult(text: cleaned, providerUsed: preferredPrimary, fallbackUsed: false)
        } catch {
            let shouldRetryPrimary = isRetryable(error)
            if shouldRetryPrimary {
                try? await Task.sleep(for: .seconds(1))
                do {
                    let primaryChunks = try chunksForProvider(primary)
                    let text = try await runChunks(
                        chunks: primaryChunks,
                        with: primary,
                        model: modelOverrides.primaryModel ?? model(for: preferredPrimary, settings: settings),
                        language: settings.language,
                        vocabularyHints: settings.vocabularyHints
                    )
                    let cleaned = cleanup(text: text, replacements: replacements)
                    return TranscriptionPipelineResult(text: cleaned, providerUsed: preferredPrimary, fallbackUsed: false)
                } catch {
                    do {
                        let fallbackChunks = try chunksForProvider(fallback)
                        let text = try await runChunks(
                            chunks: fallbackChunks,
                            with: fallback,
                            model: modelOverrides.fallbackModel ?? model(for: preferredFallback, settings: settings),
                            language: settings.language,
                            vocabularyHints: settings.vocabularyHints
                        )
                        fallbackStickyUntil = Date().addingTimeInterval(30)
                        startPrimaryReprobe(provider: primary)
                        let cleaned = cleanup(text: text, replacements: replacements)
                        return TranscriptionPipelineResult(text: cleaned, providerUsed: preferredFallback, fallbackUsed: true)
                    } catch {
                        throw TranscriptionPipelineError.retryAvailable(primary: preferredPrimary, fallback: preferredFallback)
                    }
                }
            }

            do {
                let fallbackChunks = try chunksForProvider(fallback)
                let text = try await runChunks(
                    chunks: fallbackChunks,
                    with: fallback,
                    model: modelOverrides.fallbackModel ?? model(for: preferredFallback, settings: settings),
                    language: settings.language,
                    vocabularyHints: settings.vocabularyHints
                )
                fallbackStickyUntil = Date().addingTimeInterval(30)
                startPrimaryReprobe(provider: primary)
                let cleaned = cleanup(text: text, replacements: replacements)
                return TranscriptionPipelineResult(text: cleaned, providerUsed: preferredFallback, fallbackUsed: true)
            } catch {
                throw TranscriptionPipelineError.retryAvailable(primary: preferredPrimary, fallback: preferredFallback)
            }
        }
    }

    /// Shuts down any provider-managed background processes.
    public func shutdown() async {
        for provider in providers.values {
            if let whisper = provider as? WhisperCppProvider {
                await whisper.shutdownServer()
            }
        }
    }

    /// Performs a provider connectivity probe with 6-second timeout budget.
    public func connectivityCheck(primary: ProviderKind, fallback: ProviderKind) async -> (primaryOK: Bool, fallbackOK: Bool) {
        guard let primaryProvider = providers[primary], let fallbackProvider = providers[fallback] else {
            return (false, false)
        }

        async let primaryResult = primaryProvider.checkHealth(timeoutSeconds: 6)
        async let fallbackResult = fallbackProvider.checkHealth(timeoutSeconds: 6)
        return await (primaryResult, fallbackResult)
    }

    private func provider(for kind: ProviderKind) throws -> any TranscriptionProvider {
        guard let provider = providers[kind] else {
            throw TranscriptionPipelineError.providerUnavailable(kind)
        }
        return provider
    }

    private func runChunks(
        chunks: [URL],
        with provider: any TranscriptionProvider,
        model: String,
        language: String,
        vocabularyHints: [String]
    ) async throws -> String {
        var combined: [String] = []
        var rollingContext: String?

        for chunk in chunks {
            let request = TranscriptionRequest(
                audioFileURL: chunk,
                language: language,
                model: model,
                context: rollingContext,
                vocabularyHints: vocabularyHints
            )
            let response = try await transcribeChunkWithTimeout(request: request, provider: provider)
            combined.append(response.text)
            rollingContext = String(response.text.suffix(300))
        }

        return combined.joined(separator: " ")
    }

    /// Enforces a hard timeout around provider transcription to prevent indefinite hangs.
    private func transcribeChunkWithTimeout(
        request: TranscriptionRequest,
        provider: any TranscriptionProvider
    ) async throws -> TranscriptionResponse {
        let timeoutSeconds = requestTimeoutSeconds

        return try await withThrowingTaskGroup(of: TranscriptionResponse.self) { group in
            group.addTask {
                try await provider.transcribe(request: request)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Double(timeoutSeconds)))
                throw ProviderError.timeout
            }

            defer {
                group.cancelAll()
            }

            guard let response = try await group.next() else {
                throw ProviderError.networkFailure
            }
            return response
        }
    }

    private struct PreparedSourceChunks: Sendable {
        let chunkFiles: [URL]
        let temporaryFiles: [URL]
    }

    private func prepareSourceChunks(_ audioFileURL: URL) throws -> PreparedSourceChunks {
        let chunkFiles = try chunkAudioIfNeeded(audioFileURL)
        let temporaryFiles = chunkFiles.filter { $0 != audioFileURL }
        return PreparedSourceChunks(chunkFiles: chunkFiles, temporaryFiles: temporaryFiles)
    }

    private func transcodeToFLAC(_ sourceURL: URL) throws -> URL {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QuedoUploadAudio", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }

        let destinationURL = tempRoot.appendingPathComponent("upload-\(UUID().uuidString)").appendingPathExtension("flac")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [sourceURL.path, "-f", "flac", "-d", "flac", destinationURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }

        guard process.terminationStatus == 0, fileManager.fileExists(atPath: destinationURL.path) else {
            try? fileManager.removeItem(at: destinationURL)
            throw TranscriptionPipelineError.chunkingFailed
        }

        return destinationURL
    }

    private func chunkAudioIfNeeded(_ fileURL: URL) throws -> [URL] {
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }

        let sampleRate = sourceFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return [fileURL]
        }

        let framesPerChunk = AVAudioFramePosition(sampleRate * chunkDurationSeconds)
        if sourceFile.length <= framesPerChunk {
            return [fileURL]
        }

        guard let outputFormat = AVAudioFormat(settings: sourceFile.fileFormat.settings) else {
            throw TranscriptionPipelineError.chunkingFailed
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QuedoChunks", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let readBlockFrames: AVAudioFrameCount = 8_192
        var remainingFrames = sourceFile.length
        var files: [URL] = []
        var createdPaths: [URL] = []
        var index = 0

        do {
            while remainingFrames > 0 {
                let chunkFrames = min(framesPerChunk, remainingFrames)
                let path = tempRoot.appendingPathComponent("chunk-\(UUID().uuidString)-\(index).wav")
                createdPaths.append(path)

                let chunkFile: AVAudioFile
                do {
                    chunkFile = try AVAudioFile(forWriting: path, settings: outputFormat.settings)
                } catch {
                    throw TranscriptionPipelineError.chunkingFailed
                }

                var chunkFramesRemaining = chunkFrames
                while chunkFramesRemaining > 0 {
                    let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(readBlockFrames), chunkFramesRemaining))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesToRead) else {
                        throw TranscriptionPipelineError.chunkingFailed
                    }

                    do {
                        try sourceFile.read(into: buffer, frameCount: framesToRead)
                    } catch {
                        throw TranscriptionPipelineError.chunkingFailed
                    }

                    let readFrames = AVAudioFramePosition(buffer.frameLength)
                    if readFrames == 0 {
                        chunkFramesRemaining = 0
                        remainingFrames = 0
                        break
                    }

                    do {
                        try chunkFile.write(from: buffer)
                    } catch {
                        throw TranscriptionPipelineError.chunkingFailed
                    }

                    chunkFramesRemaining -= readFrames
                    remainingFrames -= readFrames
                }

                files.append(path)
                index += 1
            }
        } catch {
            cleanupTemporaryFiles(createdPaths)
            throw error
        }

        return files
    }

    private func cleanupTemporaryFiles(_ files: [URL]) {
        for file in Set(files) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func cleanup(text: String, replacements: [String: String]) -> String {
        var output = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let hallucinationPatterns = [
            "Thanks for watching.",
            "Thank you for watching.",
            "Subtitles by",
            "Please subscribe"
        ]

        for pattern in hallucinationPatterns {
            output = output.replacingOccurrences(of: pattern, with: "")
        }

        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target)
        }

        return output
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func model(for provider: ProviderKind, settings: AppSettings) -> String {
        switch provider {
        case .groq:
            return settings.provider.groqModel
        case .openAI:
            return settings.provider.openAIModel
        case .whisperCpp:
            return settings.provider.whisperCppModelPath
        case .elevenLabs:
            return settings.provider.elevenLabsModel
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else {
            return false
        }

        switch providerError {
        case .timeout, .networkFailure, .transient:
            return true
        case .terminal, .missingAPIKey, .invalidResponse:
            return false
        }
    }

    private func startPrimaryReprobe(provider: any TranscriptionProvider) {
        primaryProbeTask?.cancel()
        primaryProbeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if await provider.checkHealth(timeoutSeconds: requestTimeoutSeconds) {
                    clearFallbackStickyWindow()
                    return
                }
            }
        }
    }

    private func clearFallbackStickyWindow() {
        fallbackStickyUntil = nil
    }
}
