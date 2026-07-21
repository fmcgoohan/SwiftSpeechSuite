import Foundation
import Testing
@testable import ElevenLabsSwift

private struct FakePerformer: URLRequestPerforming {
    let statusCode: Int?
    let responseData: Data
    let throwError: Error?

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let throwError { throw throwError }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode ?? 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}

private struct FakeNetworkFailure: Error {}

@Test func synthesizeReturnsDataOn200() async throws {
    let expected = Data("fake-audio-bytes".utf8)
    let client = ElevenLabsClient(apiKey: "key", performer: FakePerformer(statusCode: 200, responseData: expected, throwError: nil))
    let result = try await client.synthesize(text: "hello", voiceId: "voice1", modelId: "model1")
    #expect(result == expected)
}

@Test func synthesizeThrowsRequestFailedOnNon2xx() async throws {
    let body = Data(#"{"detail":{"message":"Unusual activity detected. Free Tier usage disabled."}}"#.utf8)
    let client = ElevenLabsClient(apiKey: "bad-key", performer: FakePerformer(statusCode: 403, responseData: body, throwError: nil))
    do {
        _ = try await client.synthesize(text: "hello", voiceId: "voice1", modelId: "model1")
        Issue.record("expected synthesize to throw on a 403 response")
    } catch let error as ElevenLabsError {
        // The response body must survive into the error — that's the whole
        // point of this shape (see the real-world debugging this fixed).
        #expect(error == .requestFailed(statusCode: 403, body: "{\"detail\":{\"message\":\"Unusual activity detected. Free Tier usage disabled.\"}}"))
    }
}

@Test func synthesizeWrapsUnderlyingNetworkErrors() async throws {
    let client = ElevenLabsClient(apiKey: "key", performer: FakePerformer(statusCode: nil, responseData: Data(), throwError: FakeNetworkFailure()))
    do {
        _ = try await client.synthesize(text: "hello", voiceId: "voice1", modelId: "model1")
        Issue.record("expected synthesize to throw on a network failure")
    } catch let error as ElevenLabsError {
        guard case .networkError = error else {
            Issue.record("expected .networkError, got \(error)")
            return
        }
    }
}

@Test func validateKeySucceedsOn200() async {
    let client = ElevenLabsClient(apiKey: "key", performer: FakePerformer(statusCode: 200, responseData: Data(), throwError: nil))
    #expect(await client.validateKey() == .valid)
}

@Test func validateKeyFailsOnUnauthorizedWithBody() async {
    let body = Data(#"{"detail":"invalid_api_key"}"#.utf8)
    let client = ElevenLabsClient(apiKey: "key", performer: FakePerformer(statusCode: 401, responseData: body, throwError: nil))
    guard case .invalid(let statusCode, let responseBody) = await client.validateKey() else {
        Issue.record("expected .invalid")
        return
    }
    #expect(statusCode == 401)
    #expect(responseBody.contains("invalid_api_key"))
}

@Test func validateKeyReportsNetworkError() async {
    let client = ElevenLabsClient(apiKey: "key", performer: FakePerformer(statusCode: nil, responseData: Data(), throwError: FakeNetworkFailure()))
    guard case .networkError = await client.validateKey() else {
        Issue.record("expected .networkError")
        return
    }
}
