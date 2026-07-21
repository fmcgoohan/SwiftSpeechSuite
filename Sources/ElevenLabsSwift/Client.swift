import Foundation

/// Verified against ElevenLabs' current API docs (not assumed from
/// training data) — see mac PLAN.md/session notes for the fetch. Endpoint,
/// header, body shape, and response type are all confirmed current as of
/// this feature's implementation.
public protocol URLRequestPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionRequestPerformer: URLRequestPerforming {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public enum ElevenLabsError: Error, Sendable, Equatable {
    /// `body` is ElevenLabs' own JSON error detail (truncated) — e.g.
    /// "Unusual activity detected. Free Tier usage disabled..." for a 403,
    /// or a specific voice/model access message. Without this, every
    /// failure looks identical and is nearly impossible to diagnose from
    /// the status code alone.
    case requestFailed(statusCode: Int, body: String)
    case networkError(String)
    case invalidResponse
}

public enum KeyValidation: Sendable, Equatable {
    case valid
    case invalid(statusCode: Int, body: String)
    case networkError(String)
}

public struct ElevenLabsClient: Sendable {
    private let apiKey: String
    private let performer: URLRequestPerforming
    private let baseURL: URL

    public init(
        apiKey: String,
        performer: URLRequestPerforming = URLSessionRequestPerformer(),
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!
    ) {
        self.apiKey = apiKey
        self.performer = performer
        self.baseURL = baseURL
    }

    /// POST /v1/text-to-speech/{voice_id} — returns raw audio bytes
    /// (application/octet-stream, MP3 by default at mp3_44100_128),
    /// directly playable via AVAudioPlayer(data:).
    public func synthesize(text: String, voiceId: String, modelId: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/text-to-speech/\(voiceId)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": modelId])

        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw ElevenLabsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ElevenLabsError.requestFailed(statusCode: http.statusCode, body: Self.errorBody(from: data))
        }
        return data
    }

    /// GET /v2/voices?page_size=1 — a 200 response confirms the key is
    /// valid without fetching a large voice list. Used by SFDoctor.
    public func validateKey() async -> KeyValidation {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("v2/voices"), resolvingAgainstBaseURL: false) else {
            return .invalid(statusCode: -1, body: "could not build request URL")
        }
        components.queryItems = [URLQueryItem(name: "page_size", value: "1")]
        guard let url = components.url else {
            return .invalid(statusCode: -1, body: "could not build request URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        do {
            let (data, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse else { return .invalid(statusCode: -1, body: "non-HTTP response") }
            if (200..<300).contains(http.statusCode) { return .valid }
            return .invalid(statusCode: http.statusCode, body: Self.errorBody(from: data))
        } catch {
            return .networkError(String(describing: error))
        }
    }

    /// ElevenLabs returns a JSON body like {"detail": {"message": "..."}}
    /// (or a plain string) on failure — surface whatever text is there
    /// rather than just the status code.
    private static func errorBody(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(500))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await performer.perform(request)
        } catch let error as ElevenLabsError {
            throw error
        } catch {
            throw ElevenLabsError.networkError(error.localizedDescription)
        }
    }
}
