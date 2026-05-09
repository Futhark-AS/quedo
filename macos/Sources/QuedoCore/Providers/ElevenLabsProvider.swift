import Foundation

/// ElevenLabs Speech to Text provider implementation.
public struct ElevenLabsProvider: TranscriptionProvider {
    /// Provider family identifier.
    public let kind: ProviderKind = .elevenLabs

    private let session: URLSession
    private let timeoutSeconds: Int
    private let apiKeyProvider: @Sendable () async throws -> String

    /// Creates an ElevenLabs provider.
    public init(
        session: URLSession = .shared,
        timeoutSeconds: Int,
        apiKeyProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.apiKeyProvider = apiKeyProvider
    }

    /// Transcribes audio with the ElevenLabs Speech to Text API.
    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        let apiKey = try await apiKeyProvider()
        guard !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }

        var multipart = MultipartFormData()
        multipart.addField(name: "model_id", value: request.model)
        if request.language != "auto" {
            multipart.addField(name: "language_code", value: request.language)
        }

        let audioData = try Data(contentsOf: request.audioFileURL)
        multipart.addFile(
            name: "file",
            filename: request.audioFileURL.lastPathComponent,
            mimeType: mimeType(for: request.audioFileURL),
            data: audioData
        )
        multipart.finalize()

        guard let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text") else {
            throw ProviderError.invalidResponse
        }

        var requestObject = URLRequest(url: endpoint)
        requestObject.httpMethod = "POST"
        requestObject.timeoutInterval = TimeInterval(timeoutSeconds)
        requestObject.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        requestObject.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        requestObject.httpBody = multipart.data()

        do {
            let (data, response) = try await session.data(for: requestObject)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse
            }

            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(ElevenLabsTextResponse.self, from: data)
                return TranscriptionResponse(text: decoded.text, provider: .elevenLabs, isPartial: false)
            case 408, 429, 500, 502, 503, 504:
                throw ProviderError.transient(statusCode: http.statusCode)
            default:
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                throw ProviderError.terminal(statusCode: http.statusCode, message: body)
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ProviderError.timeout
        } catch let provider as ProviderError {
            throw provider
        } catch {
            throw ProviderError.networkFailure
        }
    }

    /// Checks if ElevenLabs endpoint is reachable.
    public func checkHealth(timeoutSeconds: Int) async -> Bool {
        let apiKey: String
        do {
            apiKey = try await apiKeyProvider()
        } catch {
            return false
        }

        guard !apiKey.isEmpty, let url = URL(string: "https://api.elevenlabs.io/v1/user") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "flac":
            return "audio/flac"
        case "caf":
            return "audio/x-caf"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        default:
            return "application/octet-stream"
        }
    }
}

private struct ElevenLabsTextResponse: Codable {
    let text: String
}
