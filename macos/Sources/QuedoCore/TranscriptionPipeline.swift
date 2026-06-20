import AVFoundation
import Foundation

/// Errors returned by the transcription pipeline.
public enum TranscriptionPipelineError: Error, Sendable {
    /// No provider instance for requested kind.
    case providerUnavailable(ProviderKind)
    /// Both primary and fallback providers failed.
    case retryAvailable(
        primary: ProviderKind,
        fallback: ProviderKind,
        primaryErrorDescription: String,
        fallbackErrorDescription: String
    )
    /// Audio file could not be chunked.
    case chunkingFailed
}

public extension TranscriptionPipelineError {
    /// Human-readable diagnostic summary.
    var diagnosticDescription: String {
        switch self {
        case let .providerUnavailable(provider):
            return "\(provider.rawValue) provider is unavailable"
        case let .retryAvailable(primary, fallback, primaryErrorDescription, fallbackErrorDescription):
            return "\(primary.rawValue) failed (\(primaryErrorDescription)); \(fallback.rawValue) failed (\(fallbackErrorDescription))"
        case .chunkingFailed:
            return "audio chunking/conversion failed"
        }
    }
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
                    let primaryErrorDescription = describe(error)
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
                        throw TranscriptionPipelineError.retryAvailable(
                            primary: preferredPrimary,
                            fallback: preferredFallback,
                            primaryErrorDescription: primaryErrorDescription,
                            fallbackErrorDescription: describe(error)
                        )
                    }
                }
            }

            let primaryErrorDescription = describe(error)
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
                throw TranscriptionPipelineError.retryAvailable(
                    primary: preferredPrimary,
                    fallback: preferredFallback,
                    primaryErrorDescription: primaryErrorDescription,
                    fallbackErrorDescription: describe(error)
                )
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

    private struct WAVMetadata {
        let formatData: Data
        let sampleRate: Double
        let blockAlign: Int
        let dataOffset: Int
        let dataSize: Int
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
        if fileURL.pathExtension.lowercased() == "wav",
           let wavChunks = try chunkWAVAudioIfNeeded(fileURL) {
            return wavChunks
        }

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

        let outputFormat = sourceFile.processingFormat
        guard outputFormat.channelCount > 0 else {
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

    private func chunkWAVAudioIfNeeded(_ fileURL: URL) throws -> [URL]? {
        guard let metadata = try parseWAVMetadata(fileURL) else {
            return nil
        }

        let framesPerChunk = Int64(metadata.sampleRate * chunkDurationSeconds)
        guard framesPerChunk > 0, metadata.blockAlign > 0 else {
            throw TranscriptionPipelineError.chunkingFailed
        }

        let bytesPerChunk = framesPerChunk * Int64(metadata.blockAlign)
        guard Int64(metadata.dataSize) > bytesPerChunk else {
            return [fileURL]
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QuedoChunks", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }

        var remainingBytes = Int64(metadata.dataSize)
        var sourceOffset = metadata.dataOffset
        var files: [URL] = []
        var createdPaths: [URL] = []
        var index = 0
        let sourceHandle: FileHandle

        do {
            sourceHandle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }
        defer {
            try? sourceHandle.close()
        }

        do {
            while remainingBytes > 0 {
                var chunkBytes = min(bytesPerChunk, remainingBytes)
                chunkBytes -= chunkBytes % Int64(metadata.blockAlign)
                guard chunkBytes > 0 else {
                    throw TranscriptionPipelineError.chunkingFailed
                }

                let endOffset = sourceOffset + Int(chunkBytes)
                guard let audioData = readData(from: sourceHandle, offset: UInt64(sourceOffset), length: Int(chunkBytes)),
                      endOffset <= metadata.dataOffset + metadata.dataSize else {
                    throw TranscriptionPipelineError.chunkingFailed
                }

                let path = tempRoot.appendingPathComponent("chunk-\(UUID().uuidString)-\(index).wav")
                createdPaths.append(path)

                let chunkData = try makeWAVData(formatData: metadata.formatData, audioData: audioData)
                try chunkData.write(to: path, options: .atomic)

                files.append(path)
                sourceOffset = endOffset
                remainingBytes -= chunkBytes
                index += 1
            }
        } catch {
            cleanupTemporaryFiles(createdPaths)
            throw TranscriptionPipelineError.chunkingFailed
        }

        return files
    }

    private func parseWAVMetadata(_ fileURL: URL) throws -> WAVMetadata? {
        let fileSize: UInt64
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }

        guard fileSize >= 12 else {
            return nil
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw TranscriptionPipelineError.chunkingFailed
        }
        defer {
            try? handle.close()
        }

        let riffHeader = handle.readData(ofLength: 12)
        guard riffHeader.count == 12,
              asciiString(riffHeader, offset: 0, length: 4) == "RIFF",
              asciiString(riffHeader, offset: 8, length: 4) == "WAVE" else {
            return nil
        }

        var formatData: Data?
        var sampleRate: Double?
        var blockAlign: Int?
        var dataOffset: UInt64?
        var dataSize: UInt64?
        var offset: UInt64 = 12

        while offset + 8 <= fileSize {
            handle.seek(toFileOffset: offset)
            let chunkHeader = handle.readData(ofLength: 8)
            guard chunkHeader.count == 8,
                  let chunkID = asciiString(chunkHeader, offset: 0, length: 4) else {
                return nil
            }

            let chunkSize = UInt64(readLittleEndianUInt32(chunkHeader, offset: 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= fileSize else {
                return nil
            }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else {
                    return nil
                }

                guard let currentFormatData = readData(from: handle, offset: payloadStart, length: Int(chunkSize)) else {
                    return nil
                }
                formatData = currentFormatData
                sampleRate = Double(readLittleEndianUInt32(currentFormatData, offset: 4))
                blockAlign = Int(readLittleEndianUInt16(currentFormatData, offset: 12))
            } else if chunkID == "data" {
                dataOffset = payloadStart
                dataSize = chunkSize
            }

            offset = payloadEnd + (chunkSize % 2)
        }

        guard let formatData,
              let sampleRate,
              let blockAlign,
              let dataOffset,
              let dataSize,
              sampleRate > 0,
              blockAlign > 0,
              dataOffset <= UInt64(Int.max),
              dataSize <= UInt64(Int.max) else {
            return nil
        }

        return WAVMetadata(
            formatData: formatData,
            sampleRate: sampleRate,
            blockAlign: blockAlign,
            dataOffset: Int(dataOffset),
            dataSize: Int(dataSize)
        )
    }

    private func readData(from handle: FileHandle, offset: UInt64, length: Int) -> Data? {
        guard length >= 0 else {
            return nil
        }
        handle.seek(toFileOffset: offset)

        var data = Data()
        data.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            let part = handle.readData(ofLength: min(remaining, 1_048_576))
            guard !part.isEmpty else {
                return nil
            }
            data.append(part)
            remaining -= part.count
        }
        return data
    }

    private func makeWAVData(formatData: Data, audioData: Data) throws -> Data {
        let formatPadding = formatData.count % 2
        let dataPadding = audioData.count % 2
        let riffPayloadSize = 4 + 8 + formatData.count + formatPadding + 8 + audioData.count + dataPadding

        guard riffPayloadSize <= Int(UInt32.max),
              formatData.count <= Int(UInt32.max),
              audioData.count <= Int(UInt32.max) else {
            throw TranscriptionPipelineError.chunkingFailed
        }

        var output = Data()
        output.reserveCapacity(8 + riffPayloadSize)
        output.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        output.appendLittleEndianUInt32(UInt32(riffPayloadSize))
        output.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        output.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        output.appendLittleEndianUInt32(UInt32(formatData.count))
        output.append(formatData)
        if formatPadding == 1 {
            output.append(0)
        }
        output.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        output.appendLittleEndianUInt32(UInt32(audioData.count))
        output.append(audioData)
        if dataPadding == 1 {
            output.append(0)
        }

        return output
    }

    private func asciiString(_ data: Data, offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            return nil
        }
        return String(bytes: data[offset..<offset + length], encoding: .ascii)
    }

    private func readLittleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readLittleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
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
        case .azureSpeech:
            return settings.provider.azureSpeechModel
        case .openRouter:
            return settings.provider.openRouterModel
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

    private func describe(_ error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.diagnosticDescription
        }
        if let pipelineError = error as? TranscriptionPipelineError {
            return pipelineError.diagnosticDescription
        }
        return String(describing: error)
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

private extension Data {
    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
