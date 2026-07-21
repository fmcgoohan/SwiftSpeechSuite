import Foundation

/// Backend-neutral storage for completed audio files and their manifest.
/// Native PCM uses its streaming writer; buffered backends use this package.
public final class ReadingSessionPackage: @unchecked Sendable {
    public let directoryURL: URL
    private let writeQueue = DispatchQueue(label: "com.speakflow.reading-session-package", qos: .utility)

    public init(sessionID: UUID, baseDirectory: URL? = nil) throws {
        let root = baseDirectory ?? ReadingSessionLocations.recentSessionsDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.pruneExpiredSessions(in: root, excluding: sessionID)
        directoryURL = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func persist(_ session: ReadingSession) throws {
        try ReadingSessionManifest.write(session, to: directoryURL)
    }

    public func writeAudio(_ data: Data, fileName: String) async throws {
        guard ReadingSessionArchive.isSafeFileName(fileName) else {
            throw ReadingSessionArchiveError.invalidSessionDirectory
        }
        let destination = directoryURL.appendingPathComponent(fileName)
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                do {
                    try data.write(to: destination, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func pruneExpiredSessions(in root: URL, excluding sessionID: UUID) {
        let expiration = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children where child.lastPathComponent != sessionID.uuidString {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < expiration
            else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}

enum ReadingSessionManifest {
    static func write(_ session: ReadingSession, to directoryURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(
            to: directoryURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}
