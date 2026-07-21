import Foundation
import NaturalLanguage
import SwiftLogKit
import SwiftUI
@preconcurrency import Translation

public struct TextTranslationResult: Sendable, Equatable {
    public let sourceText: String
    public let spokenText: String
    public let sourceLanguageCode: String
    public let targetLanguageCode: String
    public let wasTranslated: Bool

    public init(
        sourceText: String,
        spokenText: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        wasTranslated: Bool
    ) {
        self.sourceText = sourceText
        self.spokenText = spokenText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.wasTranslated = wasTranslated
    }
}

public enum TranslationActivityPhase: Sendable, Equatable {
    case idle
    case checking
    case preparingLanguagePack
    case translating
    case failed
}

public enum AppleTranslationCoordinatorError: Error, LocalizedError, Equatable {
    case unableToDetectLanguage
    case unsupportedPair(source: String, target: String)
    case preparationTimedOut(source: String, target: String)
    case emptyResult(source: String, target: String)
    case superseded

    public var errorDescription: String? {
        switch self {
        case .unableToDetectLanguage:
            "SpeakFlow could not identify the source language."
        case .unsupportedPair(let source, let target):
            "On-device translation from \(source) to \(target) is not supported."
        case .preparationTimedOut(let source, let target):
            "Preparing the \(source) to \(target) language pack timed out. Try again and approve Apple's download prompt."
        case .emptyResult(let source, let target):
            "On-device translation from \(source) to \(target) returned no readable text."
        case .superseded:
            "The translation was replaced by a newer reading request."
        }
    }
}

enum TranslationOutputValidator {
    static func validate(_ text: String, source: String, target: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleTranslationCoordinatorError.emptyResult(source: source, target: target)
        }
        return text
    }
}

public enum TranslationTextChunker {
    public static let defaultMaximumCharacters = 2_400

    public static func chunks(
        _ text: String,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> [String] {
        guard maximumCharacters > 0 else { return [] }
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            for piece in split(paragraph, maximumCharacters: maximumCharacters) {
                let candidate = current.isEmpty ? piece : current + "\n\n" + piece
                if candidate.count <= maximumCharacters {
                    current = candidate
                } else {
                    if !current.isEmpty { chunks.append(current) }
                    current = piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func split(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var pieces: [String] = []
        var remainder = text[...]
        while remainder.count > maximumCharacters {
            let limit = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
            let prefix = remainder[..<limit]
            let splitIndex = prefix.lastIndex(where: { $0.isWhitespace }) ?? limit
            let piece = remainder[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            remainder = remainder[splitIndex...].drop(while: { $0.isWhitespace })
        }
        let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}

@MainActor
enum TranslationRetryPolicy {
    static let maximumAttempts = 2

    static func run<Value>(
        operation: @escaping @MainActor (Int) async throws -> Value
    ) async throws -> Value {
        var lastError: Error?
        for attempt in 0..<maximumAttempts {
            do {
                return try await operation(attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AppleTranslationCoordinatorError where error == .superseded {
                throw error
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }
}

@MainActor
public final class AppleTranslationCoordinator: ObservableObject {
    private static let preparationTimeout: Duration = .seconds(90)

    @Published public private(set) var configuration: TranslationSession.Configuration?
    @Published public private(set) var statusText = "Ready"
    @Published public private(set) var activityPhase: TranslationActivityPhase = .idle
    public var onPreparationVisibilityChanged: (@MainActor (Bool) -> Void)?

    private struct PendingRequest {
        let id: UUID
        let text: String
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<TextTranslationResult, Error>
    }

    private var pendingRequest: PendingRequest?
    private var pendingTimeoutTask: Task<Void, Never>?
    private var failureResetTask: Task<Void, Never>?
    private weak var activeSession: TranslationSession?
    private var currentRequestID: UUID?
    private let failureResetDelay: Duration

    public init() {
        failureResetDelay = .seconds(4)
    }

    init(failureResetDelay: Duration) {
        self.failureResetDelay = failureResetDelay
    }

    public func translate(_ text: String, targetLanguageCode: String) async throws -> TextTranslationResult {
        let requestID = beginRequest()
        let sample = String(text.prefix(4_000))
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: sample),
              detected != .undetermined
        else {
            fail(requestID: requestID, status: "Language detection failed")
            throw AppleTranslationCoordinatorError.unableToDetectLanguage
        }

        let sourceCode = detected.rawValue
        if Self.baseLanguage(sourceCode) == Self.baseLanguage(targetLanguageCode) {
            try requireCurrent(requestID)
            complete(
                requestID: requestID,
                status: "Already \(Self.languageName(targetLanguageCode))"
            )
            SFLog.pipeline.notice(
                "translation bypassed because source \(sourceCode, privacy: .public) already matches target \(targetLanguageCode, privacy: .public)"
            )
            return TextTranslationResult(
                sourceText: text,
                spokenText: text,
                sourceLanguageCode: sourceCode,
                targetLanguageCode: targetLanguageCode,
                wasTranslated: false
            )
        }

        let source = Locale.Language(identifier: sourceCode)
        let target = Locale.Language(identifier: targetLanguageCode)
        activityPhase = .checking
        statusText = "Checking \(Self.languageName(targetLanguageCode)) support..."
        let availability = LanguageAvailability()
        let availabilityStatus = await availability.status(from: source, to: target)
        try requireCurrent(requestID)
        guard availabilityStatus != .unsupported else {
            fail(requestID: requestID, status: "Language pair unsupported")
            throw AppleTranslationCoordinatorError.unsupportedPair(
                source: sourceCode,
                target: targetLanguageCode
            )
        }

        if availabilityStatus == .installed {
            activityPhase = .translating
            statusText = "Translating to \(Self.languageName(targetLanguageCode))..."
            do {
                let result = try await performTranslationWithRetry(
                    requestID: requestID,
                    text: text,
                    source: source,
                    target: target
                )
                try requireCurrent(requestID)
                complete(
                    requestID: requestID,
                    status: "Translated to \(Self.languageName(targetLanguageCode))"
                )
                SFLog.pipeline.notice(
                    "translated \(text.count, privacy: .public) characters from \(result.sourceLanguageCode, privacy: .public) to \(result.targetLanguageCode, privacy: .public)"
                )
                return result
            } catch is CancellationError {
                cancelCurrent(requestID: requestID)
                throw CancellationError()
            } catch let error as AppleTranslationCoordinatorError where error == .superseded {
                throw error
            } catch {
                guard currentRequestID == requestID else {
                    throw AppleTranslationCoordinatorError.superseded
                }
                fail(requestID: requestID, status: "Translation failed")
                SFLog.pipeline.error(
                    "installed on-device translation failed after retry: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }

        activityPhase = .preparingLanguagePack
        statusText = "Preparing \(Self.languageName(targetLanguageCode)) language pack..."
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequest = PendingRequest(
                    id: requestID,
                    text: text,
                    source: source,
                    target: target,
                    continuation: continuation
                )
                configuration = TranslationSession.Configuration(source: source, target: target)
                onPreparationVisibilityChanged?(true)
                pendingTimeoutTask?.cancel()
                pendingTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: Self.preparationTimeout)
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.timeoutPending(
                        id: requestID,
                        source: sourceCode,
                        target: targetLanguageCode
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(id: requestID)
            }
        }
    }

    public func cancel() {
        activeSession?.cancel()
        activeSession = nil
        cancelPending()
        currentRequestID = nil
        failureResetTask?.cancel()
        failureResetTask = nil
        activityPhase = .idle
        statusText = "Ready"
    }

    public func runPendingTranslation(using session: TranslationSession) async {
        guard let request = pendingRequest, currentRequestID == request.id else { return }
        activeSession = session
        defer {
            if activeSession === session { activeSession = nil }
        }
        do {
            try await session.prepareTranslation()
            try requireCurrent(request.id)
            guard pendingRequest?.id == request.id else {
                throw AppleTranslationCoordinatorError.superseded
            }
            activityPhase = .translating
            statusText = "Translating to \(Self.languageName(request.target.minimalIdentifier))..."
            let result = try await performTranslationWithRetry(
                requestID: request.id,
                text: request.text,
                source: request.source,
                target: request.target,
                initialSession: session
            )
            try requireCurrent(request.id)
            finish(requestID: request.id, result: .success(result))
            activityPhase = .idle
            statusText = "Translated to \(Self.languageName(request.target.minimalIdentifier))"
            SFLog.pipeline.notice(
                "translated \(request.text.count, privacy: .public) characters from \(result.sourceLanguageCode, privacy: .public) to \(result.targetLanguageCode, privacy: .public)"
            )
        } catch is CancellationError {
            cancelPending(id: request.id)
        } catch let error as AppleTranslationCoordinatorError where error == .superseded {
            finish(requestID: request.id, result: .failure(error))
        } catch {
            guard currentRequestID == request.id else { return }
            finish(requestID: request.id, result: .failure(error))
            markFailed("Translation failed")
            SFLog.pipeline.error(
                "on-device translation failed after retry: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performTranslationWithRetry(
        requestID: UUID,
        text: String,
        source: Locale.Language,
        target: Locale.Language,
        initialSession: TranslationSession? = nil
    ) async throws -> TextTranslationResult {
        try await TranslationRetryPolicy.run { attempt in
            try self.requireCurrent(requestID)
            let session: TranslationSession
            if attempt == 0, let initialSession {
                session = initialSession
            } else {
                session = TranslationSession(installedSource: source, target: target)
            }
            if attempt > 0 {
                SFLog.pipeline.notice("retrying translation with a fresh installed session")
            }
            self.activeSession = session
            defer {
                if self.activeSession === session { self.activeSession = nil }
            }
            return try await self.performTranslation(
                text: text,
                source: source,
                target: target,
                using: session
            )
        }
    }

    private func performTranslation(
        text: String,
        source: Locale.Language,
        target: Locale.Language,
        using session: TranslationSession
    ) async throws -> TextTranslationResult {
        let chunks = TranslationTextChunker.chunks(text)
        var translated: [String] = []
        translated.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let response = try await session.translate(chunk)
            translated.append(try TranslationOutputValidator.validate(
                response.targetText,
                source: source.minimalIdentifier,
                target: target.minimalIdentifier
            ))
        }
        return TextTranslationResult(
            sourceText: text,
            spokenText: translated.joined(separator: "\n\n"),
            sourceLanguageCode: source.minimalIdentifier,
            targetLanguageCode: target.minimalIdentifier,
            wasTranslated: true
        )
    }

    private func finish(requestID: UUID, result: Result<TextTranslationResult, Error>) {
        guard let request = pendingRequest, request.id == requestID else { return }
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        pendingRequest = nil
        if currentRequestID == requestID { currentRequestID = nil }
        configuration = nil
        onPreparationVisibilityChanged?(false)
        request.continuation.resume(with: result)
    }

    private func cancelPending(id: UUID? = nil) {
        guard let request = pendingRequest, id == nil || request.id == id else { return }
        if currentRequestID == request.id {
            currentRequestID = nil
            activeSession?.cancel()
            activeSession = nil
        }
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        pendingRequest = nil
        configuration = nil
        onPreparationVisibilityChanged?(false)
        request.continuation.resume(throwing: CancellationError())
        activityPhase = .idle
        statusText = "Ready"
    }

    private func timeoutPending(id: UUID, source: String, target: String) {
        guard pendingRequest?.id == id else { return }
        activeSession?.cancel()
        markFailed("Language pack preparation timed out")
        SFLog.pipeline.error(
            "translation language-pack preparation timed out from \(source, privacy: .public) to \(target, privacy: .public)"
        )
        finish(
            requestID: id,
            result: .failure(
                AppleTranslationCoordinatorError.preparationTimedOut(
                    source: source,
                    target: target
                )
            )
        )
    }

    private func markFailed(_ status: String) {
        failureResetTask?.cancel()
        activityPhase = .failed
        statusText = status
        let resetDelay = failureResetDelay
        failureResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: resetDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.activityPhase == .failed else { return }
            self.activityPhase = .idle
            self.statusText = "Ready"
            self.failureResetTask = nil
        }
    }

    private func beginRequest() -> UUID {
        failureResetTask?.cancel()
        failureResetTask = nil
        activeSession?.cancel()
        activeSession = nil
        if let pendingRequest {
            finish(
                requestID: pendingRequest.id,
                result: .failure(AppleTranslationCoordinatorError.superseded)
            )
        }
        let requestID = UUID()
        currentRequestID = requestID
        return requestID
    }

    private func requireCurrent(_ requestID: UUID) throws {
        try Task.checkCancellation()
        guard currentRequestID == requestID else {
            throw AppleTranslationCoordinatorError.superseded
        }
    }

    private func complete(requestID: UUID, status: String) {
        guard currentRequestID == requestID else { return }
        currentRequestID = nil
        activityPhase = .idle
        statusText = status
    }

    private func fail(requestID: UUID, status: String) {
        guard currentRequestID == requestID else { return }
        currentRequestID = nil
        activeSession = nil
        markFailed(status)
    }

    private func cancelCurrent(requestID: UUID) {
        guard currentRequestID == requestID else { return }
        currentRequestID = nil
        activeSession?.cancel()
        activeSession = nil
        activityPhase = .idle
        statusText = "Ready"
    }

    private static func baseLanguage(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased() ?? identifier.lowercased()
    }

    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forLanguageCode: baseLanguage(identifier)) ?? identifier
    }
}

public struct AppleTranslationHostView: View {
    @ObservedObject private var coordinator: AppleTranslationCoordinator

    public init(coordinator: AppleTranslationCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing Translation")
                .font(.headline)
            Text(coordinator.statusText)
                .foregroundStyle(.secondary)
        }
            .padding(24)
            .frame(minWidth: 360, minHeight: 130)
            .translationTask(coordinator.configuration) { session in
                await coordinator.runPendingTranslation(using: session)
            }
    }
}
