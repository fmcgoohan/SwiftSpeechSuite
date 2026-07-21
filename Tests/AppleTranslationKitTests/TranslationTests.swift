import Testing
@testable import AppleTranslationKit

private enum RetryTestError: Error {
    case transient
}

@Test func translationChunksPreserveAllWordsAndStayBounded() {
    let paragraph = (0..<120).map { "word\($0)" }.joined(separator: " ")
    let text = paragraph + "\n\n" + paragraph
    let chunks = TranslationTextChunker.chunks(text, maximumCharacters: 160)

    #expect(chunks.count > 2)
    #expect(chunks.allSatisfy { $0.count <= 160 })
    #expect(chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace) == text.split(whereSeparator: \.isWhitespace))
}

@Test func emptyTranslationTextProducesNoChunks() {
    #expect(TranslationTextChunker.chunks(" \n\n ").isEmpty)
}

@Test func emptyTranslatedChunkIsRejectedBeforeSpeech() throws {
    #expect(throws: AppleTranslationCoordinatorError.emptyResult(source: "ru", target: "en")) {
        try TranslationOutputValidator.validate("  \n", source: "ru", target: "en")
    }
    #expect(try TranslationOutputValidator.validate("Readable", source: "ru", target: "en") == "Readable")
}

@Test @MainActor func transientTranslationFailureRetriesOnce() async throws {
    var attempts = 0
    let value: String = try await TranslationRetryPolicy.run { attempt in
        attempts += 1
        if attempt == 0 { throw RetryTestError.transient }
        return "translated"
    }

    #expect(value == "translated")
    #expect(attempts == 2)
}

@Test @MainActor func cancellationIsNeverRetried() async {
    var attempts = 0
    await #expect(throws: CancellationError.self) {
        try await TranslationRetryPolicy.run { _ -> String in
            attempts += 1
            throw CancellationError()
        }
    }
    #expect(attempts == 1)
}

@Test @MainActor func retryStopsAfterTwoTransientFailures() async {
    var attempts = 0
    await #expect(throws: RetryTestError.transient) {
        try await TranslationRetryPolicy.run { _ -> String in
            attempts += 1
            throw RetryTestError.transient
        }
    }
    #expect(attempts == 2)
}

@Test @MainActor func coordinatorRecoversAfterLanguageDetectionFailure() async throws {
    let coordinator = AppleTranslationCoordinator()
    await #expect(throws: AppleTranslationCoordinatorError.unableToDetectLanguage) {
        try await coordinator.translate("1234567890", targetLanguageCode: "en")
    }
    #expect(coordinator.activityPhase == .failed)

    let english = "This is an ordinary English sentence with enough words for reliable recognition."
    let recovered = try await coordinator.translate(english, targetLanguageCode: "en-US")
    #expect(recovered.spokenText == english)
    #expect(!recovered.wasTranslated)
    #expect(coordinator.activityPhase == .idle)
    #expect(coordinator.statusText.contains("English"))
}

@Test @MainActor func cancellingCoordinatorClearsFailureState() async {
    let coordinator = AppleTranslationCoordinator()
    await #expect(throws: AppleTranslationCoordinatorError.unableToDetectLanguage) {
        try await coordinator.translate("1234567890", targetLanguageCode: "en")
    }
    coordinator.cancel()
    #expect(coordinator.activityPhase == .idle)
    #expect(coordinator.statusText == "Ready")
}

@Test @MainActor func failureStatusAutomaticallyReturnsToReady() async {
    let coordinator = AppleTranslationCoordinator(failureResetDelay: .milliseconds(20))
    await #expect(throws: AppleTranslationCoordinatorError.unableToDetectLanguage) {
        try await coordinator.translate("1234567890", targetLanguageCode: "en")
    }

    try? await Task.sleep(for: .milliseconds(60))
    #expect(coordinator.activityPhase == .idle)
    #expect(coordinator.statusText == "Ready")
}
