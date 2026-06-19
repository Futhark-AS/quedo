import AVFoundation
import XCTest
@testable import QuedoCore

final class TranscriptionPipelineTests: XCTestCase {
    func testFallbackAfterPrimaryFailure() async throws {
        let file = try makeTestWAV(name: "pipeline-test-\(UUID().uuidString)", durationSeconds: 1.0)

        let primary = MockProvider(kind: .groq, mode: .alwaysFail)
        let fallback = MockProvider(kind: .openAI, mode: .alwaysSucceed("fallback transcript"))
        let pipeline = TranscriptionPipeline(providers: [primary, fallback])

        let result = try await pipeline.transcribe(audioFileURL: file, settings: .default)
        XCTAssertEqual(result.providerUsed, .openAI)
        XCTAssertTrue(result.fallbackUsed)
        XCTAssertEqual(result.text, "fallback transcript")
    }

    func testFallbackUsesExplicitFallbackModelOverride() async throws {
        let file = try makeTestWAV(name: "pipeline-test-fallback-model-\(UUID().uuidString)", durationSeconds: 1.0)

        let requestedModels = RequestedModelCollector()
        let primary = ModelRecordingProvider(kind: .groq, mode: .alwaysFail, modelCollector: requestedModels)
        let fallback = ModelRecordingProvider(kind: .openAI, mode: .alwaysSucceed("fallback transcript"), modelCollector: requestedModels)
        let pipeline = TranscriptionPipeline(providers: [primary, fallback])

        var settings = AppSettings.default
        settings.provider.primary = .groq
        settings.provider.fallback = .openAI

        let result = try await pipeline.transcribe(
            audioFileURL: file,
            settings: settings,
            modelOverrides: TranscriptionModelOverrides(primaryModel: "primary-model", fallbackModel: "fallback-model")
        )
        let models = await requestedModels.values()

        XCTAssertEqual(result.providerUsed, .openAI)
        XCTAssertTrue(result.fallbackUsed)
        XCTAssertEqual(models[.groq], ["primary-model", "primary-model"])
        XCTAssertEqual(models[.openAI], ["fallback-model"])
    }

    func testCleanupRemovesKnownHallucinations() async throws {
        let file = try makeTestWAV(name: "pipeline-test-cleanup-\(UUID().uuidString)", durationSeconds: 1.0)

        let provider = MockProvider(kind: .groq, mode: .alwaysSucceed("Thanks for watching. hello world"))
        let backup = MockProvider(kind: .openAI, mode: .alwaysSucceed("unused"))
        let pipeline = TranscriptionPipeline(providers: [provider, backup])

        var settings = AppSettings.default
        settings.provider.primary = .groq
        settings.provider.fallback = .openAI

        let result = try await pipeline.transcribe(audioFileURL: file, settings: settings)
        XCTAssertEqual(result.text, "hello world")
    }

    func testFallbackWhenPrimaryHangsPastTimeoutBudget() async throws {
        let file = try makeTestWAV(name: "pipeline-test-hang-\(UUID().uuidString)", durationSeconds: 1.0)

        let primary = MockProvider(kind: .groq, mode: .hang)
        let fallback = MockProvider(kind: .openAI, mode: .alwaysSucceed("fallback transcript"))
        let pipeline = TranscriptionPipeline(providers: [primary, fallback], requestTimeoutSeconds: 1)

        var settings = AppSettings.default
        settings.provider.primary = .groq
        settings.provider.fallback = .openAI

        let start = Date()
        let result = try await pipeline.transcribe(audioFileURL: file, settings: settings)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.providerUsed, .openAI)
        XCTAssertTrue(result.fallbackUsed)
        XCTAssertEqual(result.text, "fallback transcript")
        XCTAssertLessThan(elapsed, 8.0)
    }

    func testRetryAvailableIncludesProviderFailureDetails() async throws {
        let file = try makeTestWAV(name: "pipeline-test-failure-details-\(UUID().uuidString)", durationSeconds: 1.0)

        let primary = MockProvider(kind: .groq, mode: .alwaysFail)
        let fallback = MockProvider(kind: .openAI, mode: .alwaysFail)
        let pipeline = TranscriptionPipeline(providers: [primary, fallback], requestTimeoutSeconds: 1)

        var settings = AppSettings.default
        settings.provider.primary = .groq
        settings.provider.fallback = .openAI

        do {
            _ = try await pipeline.transcribe(audioFileURL: file, settings: settings)
            XCTFail("Expected retryAvailable error")
        } catch let error as TranscriptionPipelineError {
            switch error {
            case let .retryAvailable(primary, fallback, primaryErrorDescription, fallbackErrorDescription):
                XCTAssertEqual(primary, .groq)
                XCTAssertEqual(fallback, .openAI)
                XCTAssertEqual(primaryErrorDescription, "temporary HTTP 503")
                XCTAssertEqual(fallbackErrorDescription, "temporary HTTP 503")
            default:
                XCTFail("Expected retryAvailable, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSplitsAudioLongerThanFiveMinutes() async throws {
        let file = try makeTestWAV(
            name: "pipeline-test-split-\(UUID().uuidString)",
            durationSeconds: 301.0
        )

        let counter = CallCounter()
        let extensions = RequestedFileExtensionCollector()
        let primary = CountingProvider(kind: .groq, counter: counter, extensionCollector: extensions)
        let fallback = MockProvider(kind: .openAI, mode: .alwaysSucceed("unused"))
        let pipeline = TranscriptionPipeline(providers: [primary, fallback], requestTimeoutSeconds: 2)

        var settings = AppSettings.default
        settings.provider.primary = .groq
        settings.provider.fallback = .openAI

        let result = try await pipeline.transcribe(audioFileURL: file, settings: settings)
        let calls = await counter.value()
        let capturedExtensions = await extensions.values()

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "chunk-1 chunk-2")
        XCTAssertEqual(result.providerUsed, .groq)
        XCTAssertFalse(result.fallbackUsed)
        XCTAssertEqual(capturedExtensions, ["flac", "flac"])
    }

    func testSplitsLongInt16WAVWithoutAudioToolboxAbort() async throws {
        let file = try makeInt16TestWAV(
            name: "pipeline-test-int16-split-\(UUID().uuidString)",
            durationSeconds: 301.0,
            sampleRate: 48_000
        )

        let counter = CallCounter()
        let extensions = RequestedFileExtensionCollector()
        let primary = CountingProvider(
            kind: .openRouter,
            counter: counter,
            extensionCollector: extensions,
            requiresFlacUpload: false
        )
        let fallback = MockProvider(kind: .groq, mode: .alwaysSucceed("unused"))
        let pipeline = TranscriptionPipeline(providers: [primary, fallback], requestTimeoutSeconds: 2)

        var settings = AppSettings.default
        settings.provider.primary = .openRouter
        settings.provider.fallback = .groq

        let result = try await pipeline.transcribe(audioFileURL: file, settings: settings)
        let calls = await counter.value()
        let capturedExtensions = await extensions.values()

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result.text, "chunk-1 chunk-2")
        XCTAssertEqual(result.providerUsed, .openRouter)
        XCTAssertFalse(result.fallbackUsed)
        XCTAssertEqual(capturedExtensions, ["wav", "wav"])
    }

    func testUploadsFlacWhenInputIsWAV() async throws {
        let file = try makeTestWAV(
            name: "pipeline-test-upload-flac-\(UUID().uuidString)",
            durationSeconds: 1.0
        )

        let counter = CallCounter()
        let extensions = RequestedFileExtensionCollector()
        let primary = CountingProvider(kind: .groq, counter: counter, extensionCollector: extensions)
        let fallback = MockProvider(kind: .openAI, mode: .alwaysSucceed("unused"))
        let pipeline = TranscriptionPipeline(providers: [primary, fallback], requestTimeoutSeconds: 2)

        var settings = AppSettings.default
        settings.provider.primary = .groq
        settings.provider.fallback = .openAI

        _ = try await pipeline.transcribe(audioFileURL: file, settings: settings)
        let calls = await counter.value()
        let capturedExtensions = await extensions.values()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(capturedExtensions, ["flac"])
    }

    func testSkipsFlacConversionForProvidersThatDoNotRequireFlacUpload() async throws {
        let file = try makeTestWAV(
            name: "pipeline-test-upload-raw-\(UUID().uuidString)",
            durationSeconds: 1.0
        )

        let counter = CallCounter()
        let extensions = RequestedFileExtensionCollector()
        let primary = CountingProvider(
            kind: .whisperCpp,
            counter: counter,
            extensionCollector: extensions,
            requiresFlacUpload: false
        )
        let fallback = MockProvider(kind: .openAI, mode: .alwaysSucceed("unused"))
        let pipeline = TranscriptionPipeline(providers: [primary, fallback], requestTimeoutSeconds: 2)

        var settings = AppSettings.default
        settings.provider.primary = .whisperCpp
        settings.provider.fallback = .openAI

        _ = try await pipeline.transcribe(audioFileURL: file, settings: settings)
        let calls = await counter.value()
        let capturedExtensions = await extensions.values()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(capturedExtensions, ["wav"])
    }
}

private actor CallCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private actor RequestedFileExtensionCollector {
    private var valuesInternal: [String] = []

    func append(_ pathExtension: String) {
        valuesInternal.append(pathExtension)
    }

    func values() -> [String] {
        valuesInternal
    }
}

private actor RequestedModelCollector {
    private var valuesInternal: [ProviderKind: [String]] = [:]

    func append(_ model: String, for provider: ProviderKind) {
        valuesInternal[provider, default: []].append(model)
    }

    func values() -> [ProviderKind: [String]] {
        valuesInternal
    }
}

private struct ModelRecordingProvider: TranscriptionProvider {
    enum Mode {
        case alwaysFail
        case alwaysSucceed(String)
    }

    let kind: ProviderKind
    let mode: Mode
    let modelCollector: RequestedModelCollector

    func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        await modelCollector.append(request.model, for: kind)
        switch mode {
        case .alwaysFail:
            throw ProviderError.transient(statusCode: 503)
        case let .alwaysSucceed(text):
            return TranscriptionResponse(text: text, provider: kind, isPartial: false)
        }
    }

    func checkHealth(timeoutSeconds: Int) async -> Bool {
        _ = timeoutSeconds
        return true
    }
}

private struct CountingProvider: TranscriptionProvider {
    let kind: ProviderKind
    let counter: CallCounter
    let extensionCollector: RequestedFileExtensionCollector
    let requiresFlacUpload: Bool

    var requiresFLACUpload: Bool {
        requiresFlacUpload
    }

    init(
        kind: ProviderKind,
        counter: CallCounter,
        extensionCollector: RequestedFileExtensionCollector,
        requiresFlacUpload: Bool = true
    ) {
        self.kind = kind
        self.counter = counter
        self.extensionCollector = extensionCollector
        self.requiresFlacUpload = requiresFlacUpload
    }

    func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        await extensionCollector.append(request.audioFileURL.pathExtension.lowercased())
        let callNumber = await counter.increment()
        return TranscriptionResponse(text: "chunk-\(callNumber)", provider: kind, isPartial: false)
    }

    func checkHealth(timeoutSeconds: Int) async -> Bool {
        _ = timeoutSeconds
        return true
    }
}

private struct MockProvider: TranscriptionProvider {
    enum Mode {
        case alwaysFail
        case alwaysSucceed(String)
        case hang
    }

    let kind: ProviderKind
    let mode: Mode

    func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        _ = request
        switch mode {
        case .alwaysFail:
            throw ProviderError.transient(statusCode: 503)
        case let .alwaysSucceed(text):
            return TranscriptionResponse(text: text, provider: kind, isPartial: false)
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw ProviderError.timeout
        }
    }

    func checkHealth(timeoutSeconds: Int) async -> Bool {
        _ = timeoutSeconds
        switch mode {
        case .alwaysFail:
            return false
        case .alwaysSucceed:
            return true
        case .hang:
            return false
        }
    }
}

private enum TestAudioError: Error {
    case bufferAllocationFailed
}

private func makeTestWAV(name: String, durationSeconds: Double, sampleRate: Double = 16_000) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name).appendingPathExtension("wav")
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw TestAudioError.bufferAllocationFailed
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount = AVAudioFrameCount(max(1, Int(durationSeconds * sampleRate)))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw TestAudioError.bufferAllocationFailed
    }

    buffer.frameLength = frameCount
    if let channel = buffer.floatChannelData?.pointee {
        channel.update(repeating: 0, count: Int(frameCount))
    }

    try file.write(from: buffer)
    return url
}

private func makeInt16TestWAV(name: String, durationSeconds: Double, sampleRate: Double) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name).appendingPathExtension("wav")
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    let channels = UInt16(1)
    let bitsPerSample = UInt16(16)
    let blockAlign = channels * (bitsPerSample / 8)
    let sampleRateValue = UInt32(sampleRate)
    let byteRate = sampleRateValue * UInt32(blockAlign)
    let frameCount = UInt32(max(1, Int(durationSeconds * sampleRate)))
    let dataSize = frameCount * UInt32(blockAlign)
    let riffPayloadSize = UInt32(4 + 8 + 16 + 8) + dataSize

    guard sampleRateValue > 0, dataSize > 0 else {
        throw TestAudioError.bufferAllocationFailed
    }

    var wav = Data()
    wav.reserveCapacity(Int(44 + dataSize))
    wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
    wav.appendLittleEndianUInt32(riffPayloadSize)
    wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
    wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
    wav.appendLittleEndianUInt32(16)
    wav.appendLittleEndianUInt16(1)
    wav.appendLittleEndianUInt16(channels)
    wav.appendLittleEndianUInt32(sampleRateValue)
    wav.appendLittleEndianUInt32(byteRate)
    wav.appendLittleEndianUInt16(blockAlign)
    wav.appendLittleEndianUInt16(bitsPerSample)
    wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
    wav.appendLittleEndianUInt32(dataSize)
    wav.append(Data(repeating: 0, count: Int(dataSize)))
    try wav.write(to: url, options: .atomic)

    return url
}

private extension Data {
    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
