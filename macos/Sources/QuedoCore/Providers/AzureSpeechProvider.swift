import Foundation

/// Azure Speech LLM Speech transcription provider implementation.
public struct AzureSpeechProvider: TranscriptionProvider {
    /// Provider family identifier.
    public let kind: ProviderKind = .azureSpeech

    private let session: URLSession
    private let timeoutSeconds: Int
    private let apiKeyProvider: @Sendable () async throws -> String
    private let endpointProvider: @Sendable () async throws -> String

    /// Creates an Azure Speech provider.
    public init(
        session: URLSession = .shared,
        timeoutSeconds: Int,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        endpointProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.timeoutSeconds = timeoutSeconds
        self.apiKeyProvider = apiKeyProvider
        self.endpointProvider = endpointProvider
    }

    /// Transcribes audio with Azure Speech LLM Speech enhanced mode.
    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        let apiKey = try await apiKeyProvider()
        guard !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey
        }

        guard let endpoint = try await makeEndpointURL(path: "speechtotext/transcriptions:transcribe", query: "api-version=2025-10-15") else {
            throw ProviderError.invalidResponse
        }

        let definition = try requestDefinition(for: request)
        var multipart = MultipartFormData()
        multipart.addField(name: "definition", value: definition)

        let audioData = try Data(contentsOf: request.audioFileURL)
        multipart.addFile(
            name: "audio",
            filename: request.audioFileURL.lastPathComponent,
            mimeType: mimeType(for: request.audioFileURL),
            data: audioData
        )
        multipart.finalize()

        var requestObject = URLRequest(url: endpoint)
        requestObject.httpMethod = "POST"
        requestObject.timeoutInterval = TimeInterval(timeoutSeconds)
        requestObject.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        requestObject.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        requestObject.httpBody = multipart.data()

        do {
            let (data, response) = try await session.data(for: requestObject)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse
            }

            switch http.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(AzureSpeechTranscribeResult.self, from: data)
                return TranscriptionResponse(text: decoded.transcriptText, provider: .azureSpeech, isPartial: false)
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

    /// Checks if Azure Speech endpoint accepts the configured key.
    public func checkHealth(timeoutSeconds: Int) async -> Bool {
        let apiKey: String
        do {
            apiKey = try await apiKeyProvider()
        } catch {
            return false
        }

        guard !apiKey.isEmpty, let url = try? await makeEndpointURL(path: "sts/v1.0/issueToken") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()

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

    private func requestDefinition(for request: TranscriptionRequest) throws -> String {
        var definition = AzureSpeechTranscribeDefinition(
            locales: nil,
            phraseList: nil,
            enhancedMode: AzureSpeechEnhancedMode(enabled: true, model: request.model)
        )

        if request.language != "auto" {
            definition.locales = [request.language]
        }

        if supportsPhraseList(model: request.model) {
            let phrases = Array(
                request.vocabularyHints
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(200)
            )
            if !phrases.isEmpty {
                definition.phraseList = AzureSpeechPhraseList(phrases: phrases)
            }
        }

        let data = try JSONEncoder().encode(definition)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProviderError.invalidResponse
        }
        return json
    }

    private func supportsPhraseList(model: String) -> Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mai-transcribe-1.5"
    }

    private func makeEndpointURL(path: String, query: String? = nil) async throws -> URL? {
        let endpoint = try await endpointProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            return nil
        }

        var base = endpoint
        if !base.contains("://") {
            base = "https://\(base)"
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }

        let querySuffix = query.map { "?\($0)" } ?? ""
        return URL(string: "\(base)/\(path)\(querySuffix)")
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
        case "ogg", "opus":
            return "audio/ogg"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }
}

private struct AzureSpeechTranscribeDefinition: Encodable {
    var locales: [String]?
    var phraseList: AzureSpeechPhraseList?
    let enhancedMode: AzureSpeechEnhancedMode
}

private struct AzureSpeechPhraseList: Encodable {
    let phrases: [String]
}

private struct AzureSpeechEnhancedMode: Encodable {
    let enabled: Bool
    let model: String
}

private struct AzureSpeechTranscribeResult: Decodable {
    let combinedPhrases: [AzureSpeechCombinedPhrase]?
    let phrases: [AzureSpeechPhrase]?

    var transcriptText: String {
        let combined = (combinedPhrases ?? [])
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !combined.isEmpty {
            return combined.joined(separator: " ")
        }

        return (phrases ?? [])
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }
}

private struct AzureSpeechCombinedPhrase: Decodable {
    let text: String
}

private struct AzureSpeechPhrase: Decodable {
    let text: String
}
