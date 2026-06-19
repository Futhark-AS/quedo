import Foundation

/// OpenRouter speech-to-text provider implementation.
public struct OpenRouterProvider: TranscriptionProvider {
    /// Provider family identifier.
    public let kind: ProviderKind = .openRouter

    private let session: URLSession
    private let timeoutSeconds: Int
    private let apiKeyProvider: @Sendable () async throws -> String

    /// Creates an OpenRouter provider.
    public init(
        session: URLSession = .shared,
        timeoutSeconds: Int,
        apiKeyProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.apiKeyProvider = apiKeyProvider
    }

    /// Transcribes audio with OpenRouter's dedicated STT endpoint.
    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        let apiKey = try await apiKeyProvider()
        guard !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }

        let audioData = try Data(contentsOf: request.audioFileURL)
        let body = OpenRouterTranscriptionRequest(
            model: request.model,
            inputAudio: OpenRouterInputAudio(
                data: audioData.base64EncodedString(),
                format: audioFormat(for: request.audioFileURL)
            ),
            language: request.language == "auto" ? nil : request.language
        )

        guard let endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions") else {
            throw ProviderError.invalidResponse
        }

        var requestObject = URLRequest(url: endpoint)
        requestObject.httpMethod = "POST"
        requestObject.timeoutInterval = TimeInterval(timeoutSeconds)
        requestObject.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        requestObject.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requestObject.setValue("Quedo", forHTTPHeaderField: "X-Title")
        requestObject.httpBody = try JSONEncoder().encode(body)

        do {
            let (data, response) = try await session.data(for: requestObject)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse
            }

            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(OpenRouterTranscriptionResponse.self, from: data)
                return TranscriptionResponse(text: decoded.text, provider: .openRouter, isPartial: false)
            case 408, 429, 500, 502, 503, 504, 524, 529:
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

    /// Checks if OpenRouter accepts the configured key.
    public func checkHealth(timeoutSeconds: Int) async -> Bool {
        let apiKey: String
        do {
            apiKey = try await apiKeyProvider()
        } catch {
            return false
        }

        guard !apiKey.isEmpty, let url = URL(string: "https://openrouter.ai/api/v1/key") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

    private func audioFormat(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "wav"
        case "flac":
            return "flac"
        case "mp3":
            return "mp3"
        case "m4a":
            return "m4a"
        case "ogg", "opus":
            return "ogg"
        case "webm":
            return "webm"
        case "aac":
            return "aac"
        default:
            return "flac"
        }
    }
}

private struct OpenRouterTranscriptionRequest: Encodable {
    let model: String
    let inputAudio: OpenRouterInputAudio
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case language
    }
}

private struct OpenRouterInputAudio: Encodable {
    let data: String
    let format: String
}

private struct OpenRouterTranscriptionResponse: Decodable {
    let text: String
}
