import Foundation
import XCTest
@testable import QuedoCore

final class AzureSpeechProviderTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        AzureSpeechURLProtocol.handler = nil
    }

    func testAzureSpeechProviderBuildsMaiTranscribeRequest() async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("azure-speech-provider-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try Data("audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AzureSpeechURLProtocol.self]
        let session = URLSession(configuration: configuration)

        AzureSpeechURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://example.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "secret")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

            let body = String(data: Self.bodyData(from: request), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("name=\"definition\""))
            XCTAssertTrue(body.contains("\"model\":\"mai-transcribe-1.5\""))
            XCTAssertTrue(body.contains("\"locales\":[\"en\"]"))
            XCTAssertTrue(body.contains("\"phraseList\""))
            XCTAssertTrue(body.contains("\"Quedo\""))
            XCTAssertTrue(body.contains("\"Futhark\""))
            XCTAssertTrue(body.contains("name=\"audio\"; filename=\"\(audioURL.lastPathComponent)\""))

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(#"{"durationMilliseconds":1000,"combinedPhrases":[{"text":"hello Quedo"}],"phrases":[]}"#.utf8)
            return (response, data)
        }

        let provider = AzureSpeechProvider(
            session: session,
            timeoutSeconds: 12,
            apiKeyProvider: { "secret" },
            endpointProvider: { "example.cognitiveservices.azure.com/" }
        )
        let request = TranscriptionRequest(
            audioFileURL: audioURL,
            language: "en",
            model: "mai-transcribe-1.5",
            context: "ignored by MAI provider",
            vocabularyHints: ["Quedo", "Futhark"]
        )

        let response = try await provider.transcribe(request: request)

        XCTAssertEqual(response.provider, .azureSpeech)
        XCTAssertEqual(response.text, "hello Quedo")
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

private final class AzureSpeechURLProtocol: URLProtocol, @unchecked Sendable {
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
