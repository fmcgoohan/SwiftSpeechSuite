import Foundation

public struct ReadingContinuationRequest: Sendable, Equatable {
    /// URL scheme for continuation deep links. Override once at launch to match
    /// your app's registered scheme (e.g. `"speakflow"`); defaults neutrally.
    public nonisolated(unsafe) static var scheme = "ttssession"
    /// URL host component for continuation deep links.
    public nonisolated(unsafe) static var host = "continue"

    public let sessionID: UUID
    public let origin: ReadingSessionOrigin

    public init(sessionID: UUID, origin: ReadingSessionOrigin) {
        self.sessionID = sessionID
        self.origin = origin
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let queryItems = components.queryItems ?? []
        guard let sessionValue = queryItems.first(where: { $0.name == "session" })?.value,
              let sessionID = UUID(uuidString: sessionValue),
              let originValue = queryItems.first(where: { $0.name == "origin" })?.value,
              let origin = ReadingSessionOrigin(rawValue: originValue)
        else { return nil }
        self.init(sessionID: sessionID, origin: origin)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionID.uuidString),
            URLQueryItem(name: "origin", value: origin.rawValue),
        ]
        return components.url!
    }
}

/// How a backend resumes a partially-synthesized reading. Which backend uses
/// which strategy is app policy, so the caller supplies it; the algorithms
/// themselves live here and are reusable across apps.
public enum SynthesisContinuationStrategy: Sendable, Equatable {
    /// Resume from a UTF-16 text offset (engines with word/character alignment).
    case textOffset
    /// Resume from the first audio-incomplete segment boundary (streamed engines
    /// whose manifests carry no word alignment).
    case segmentBoundary
    /// This backend cannot resume mid-reading.
    case none
}

public extension ReadingSession {
    /// Text that was never fully synthesized, computed per the given resume
    /// `strategy`. Returns `nil` when nothing remains or the strategy is `.none`.
    func synthesisContinuationText(strategy: SynthesisContinuationStrategy) -> String? {
        switch strategy {
        case .textOffset:
            guard let utf16Offset = checkpoint.textOffset else { return text }
            let bounded = min(max(utf16Offset, 0), text.utf16.count)
            let index = String.Index(utf16Offset: bounded, in: text)
            let remainder = String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        case .segmentBoundary:
            guard let firstIncomplete = segments.firstIndex(where: { !$0.audioComplete }) else { return nil }
            let remainder = segments[firstIncomplete...]
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        case .none:
            return nil
        }
    }
}
