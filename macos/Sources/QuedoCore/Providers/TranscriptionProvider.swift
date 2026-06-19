import Foundation

/// Provider request payload.
public struct TranscriptionRequest: Sendable {
    /// Audio file URL.
    public let audioFileURL: URL
    /// Language override or `auto`.
    public let language: String
    /// Selected model identifier.
    public let model: String
    /// Context text from previous chunks.
    public let context: String?
    /// Vocabulary hints for deterministic cleanup.
    public let vocabularyHints: [String]

    /// Creates a transcription request.
    public init(audioFileURL: URL, language: String, model: String, context: String?, vocabularyHints: [String]) {
        self.audioFileURL = audioFileURL
        self.language = language
        self.model = model
        self.context = context
        self.vocabularyHints = vocabularyHints
    }
}

/// Provider response payload.
public struct TranscriptionResponse: Sendable {
    /// Final transcript.
    public let text: String
    /// Provider that produced output.
    public let provider: ProviderKind
    /// Indicates whether response represents a partial stream update.
    public let isPartial: Bool

    /// Creates a transcription response.
    public init(text: String, provider: ProviderKind, isPartial: Bool) {
        self.text = text
        self.provider = provider
        self.isPartial = isPartial
    }
}

/// Structured provider error categories.
public enum ProviderError: Error, Sendable {
    /// Request timed out.
    case timeout
    /// Network transport failure.
    case networkFailure
    /// Temporary provider-side issue.
    case transient(statusCode: Int)
    /// Permanent provider-side issue.
    case terminal(statusCode: Int, message: String)
    /// Missing API key.
    case missingAPIKey
    /// Malformed response payload.
    case invalidResponse
}

public extension ProviderError {
    /// Human-readable diagnostic summary.
    var diagnosticDescription: String {
        switch self {
        case .timeout:
            return "timed out"
        case .networkFailure:
            return "network request failed"
        case let .transient(statusCode):
            return "temporary HTTP \(statusCode)"
        case let .terminal(statusCode, message):
            let cleaned = message
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                return "HTTP \(statusCode)"
            }
            return "HTTP \(statusCode): \(String(cleaned.prefix(500)))"
        case .missingAPIKey:
            return "missing API key"
        case .invalidResponse:
            return "invalid response from provider"
        }
    }
}

/// Transcription provider protocol.
public protocol TranscriptionProvider: Sendable {
    /// Provider kind.
    var kind: ProviderKind { get }

    /// Indicates whether this provider requires FLAC upload conversion.
    var requiresFLACUpload: Bool { get }

    /// Runs transcription for a single request.
    func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse

    /// Checks basic provider reachability.
    func checkHealth(timeoutSeconds: Int) async -> Bool
}

public extension TranscriptionProvider {
    /// Default providers upload FLAC to match remote API expectations.
    var requiresFLACUpload: Bool { true }
}
