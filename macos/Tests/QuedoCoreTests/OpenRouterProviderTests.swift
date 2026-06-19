import Foundation
import XCTest
@testable import QuedoCore

final class OpenRouterProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        OpenRouterURLProtocol.handler = nil
    }

    func testOpenRouterProviderBuildsGenericTranscriptionRequest() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openrouter-provider-\(UUID().uuidString)")
            .appendingPathExtension("flac")
        try Data("audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterURLProtocol.self]
        let session = URLSession(configuration: configuration)

        OpenRouterURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://openrouter.ai/api/v1/audio/transcriptions"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Quedo")

            let body = try JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "microsoft/mai-transcribe-1.5")
            XCTAssertEqual(body?["language"] as? String, "en")
            let inputAudio = body?["input_audio"] as? [String: Any]
            XCTAssertEqual(inputAudio?["format"] as? String, "flac")
            XCTAssertEqual(inputAudio?["data"] as? String, Data("audio".utf8).base64EncodedString())

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"text":"hello from OpenRouter","usage":{"seconds":1.0}}"#.utf8)
            return (response, data)
        }

        let provider = OpenRouterProvider(
            session: session,
            timeoutSeconds: 12,
            apiKeyProvider: { "secret" }
        )
        let request = TranscriptionRequest(
            audioFileURL: audioURL,
            language: "en",
            model: "microsoft/mai-transcribe-1.5",
            context: nil,
            vocabularyHints: ["ignored"]
        )

        let response = try await provider.transcribe(request: request)

        XCTAssertEqual(response.provider, .openRouter)
        XCTAssertEqual(response.text, "hello from OpenRouter")
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var output = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            output.append(buffer, count: read)
        }
        return output
    }
}

private final class OpenRouterURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        _ = request
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
