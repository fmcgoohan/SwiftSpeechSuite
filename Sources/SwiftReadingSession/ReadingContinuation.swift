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

public extension ReadingSession {
    /// Text that was never fully synthesized. Audio-backed engines restart
    /// at a segment boundary because manifests do not contain word alignment.
    var synthesisContinuationText: String? {
        switch backend {
        case .onDevice:
            guard let utf16Offset = checkpoint.textOffset else { return text }
            let bounded = min(max(utf16Offset, 0), text.utf16.count)
            let index = String.Index(utf16Offset: bounded, in: text)
            let remainder = String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        case .nativeMLX, .kokoroServer:
            guard let firstIncomplete = segments.firstIndex(where: { !$0.audioComplete }) else { return nil }
            let remainder = segments[firstIncomplete...]
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        case .elevenLabs, .pageAudio:
            return nil
        }
    }
}
