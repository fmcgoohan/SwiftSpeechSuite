import Foundation

public enum ReadingSessionLocations {
    /// Caches subdirectory that holds in-progress/recent sessions. Override
    /// once at launch to brand it (e.g. `"SpeakFlowLocal"`); defaults neutrally.
    public nonisolated(unsafe) static var recentSessionsContainer = "SwiftReadingSession"
    /// Application-Support subdirectory that holds the archive of kept
    /// sessions. Override once at launch to brand it (e.g. `"SpeakFlowArchive"`).
    public nonisolated(unsafe) static var archiveContainer = "SwiftReadingSessionArchive"

    public static var recentSessionsDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(recentSessionsContainer, isDirectory: true)
            .appendingPathComponent("ReadingSessions", isDirectory: true)
    }

    public static var archiveDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(archiveContainer, isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}

public enum ReadingSessionOrigin: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case recent
    case archive

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .recent: "Recent"
        case .archive: "Archive"
        }
    }
}

public struct ReadingSessionRecord: Identifiable, Sendable, Equatable {
    public let session: ReadingSession
    public let directoryURL: URL
    public let origin: ReadingSessionOrigin

    public var id: UUID { session.id }

    public var title: String {
        if let title = session.source.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let firstLine = session.text
            .split(whereSeparator: \Character.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return "Untitled reading" }
        return firstLine.count > 80 ? String(firstLine.prefix(77)) + "..." : firstLine
    }

    public var progress: Double {
        let generated = session.segments.reduce(0) { $0 + $1.generatedAudioSeconds }
        guard generated > 0 else {
            guard !session.text.isEmpty, let offset = session.checkpoint.textOffset else { return 0 }
            return min(max(Double(offset) / Double(session.text.utf16.count), 0), 1)
        }
        let played = session.segments.reduce(0) { $0 + $1.playedAudioSeconds }
        return min(max(played / generated, 0), 1)
    }

    public var audioItems: [ReadingSessionAudioItem] {
        session.segments.compactMap { segment in
            if let fileName = segment.audioFileName,
               ReadingSessionArchive.isSafeFileName(fileName) {
                let url = directoryURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: url.path) {
                    return ReadingSessionAudioItem(segmentIndex: segment.id, url: url)
                }
            }
            if let remoteURL = segment.remoteAudioURL,
               let scheme = remoteURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return ReadingSessionAudioItem(segmentIndex: segment.id, url: remoteURL)
            }
            return nil
        }
    }

    public var audioURLs: [URL] { audioItems.map(\.url) }
}

public struct ReadingSessionAudioItem: Sendable, Equatable {
    public let segmentIndex: Int
    public let url: URL

    public init(segmentIndex: Int, url: URL) {
        self.segmentIndex = segmentIndex
        self.url = url
    }
}

public enum ReadingSessionArchiveError: Error, LocalizedError, Equatable {
    case invalidSessionDirectory
    case sessionStillActive
    case alreadyArchived

    public var errorDescription: String? {
        switch self {
        case .invalidSessionDirectory:
            "The reading session folder is invalid."
        case .sessionStillActive:
            "Stop or finish the reading before archiving it."
        case .alreadyArchived:
            "This reading is already in the archive."
        }
    }
}

public struct ReadingSessionArchive: Sendable {
    public let recentDirectory: URL
    public let archiveDirectory: URL

    public init(
        recentDirectory: URL = ReadingSessionLocations.recentSessionsDirectory,
        archiveDirectory: URL = ReadingSessionLocations.archiveDirectory
    ) {
        self.recentDirectory = recentDirectory
        self.archiveDirectory = archiveDirectory
    }

    public func records(origin: ReadingSessionOrigin) throws -> [ReadingSessionRecord] {
        let root = directory(for: origin)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return children.compactMap { try? loadRecord(at: $0, origin: origin) }
            .sorted { $0.session.createdAt > $1.session.createdAt }
    }

    public func record(id: UUID, origin: ReadingSessionOrigin) throws -> ReadingSessionRecord? {
        let candidate = directory(for: origin).appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return try loadRecord(at: candidate, origin: origin)
    }

    public func archive(_ record: ReadingSessionRecord) throws -> ReadingSessionRecord {
        guard record.origin == .recent else { throw ReadingSessionArchiveError.alreadyArchived }
        guard record.session.status == .completed || record.session.status == .stopped else {
            throw ReadingSessionArchiveError.sessionStillActive
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let destination = archiveDirectory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ReadingSessionArchiveError.alreadyArchived
        }

        let staging = archiveDirectory.appendingPathComponent(".\(record.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record.session).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        for segment in record.session.segments {
            guard let fileName = segment.audioFileName,
                  Self.isSafeFileName(fileName)
            else { continue }
            let source = record.directoryURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: staging.appendingPathComponent(fileName))
        }

        try fileManager.moveItem(at: staging, to: destination)
        return try loadRecord(at: destination, origin: .archive)
    }

    public func delete(_ record: ReadingSessionRecord) throws {
        let expectedRoot = directory(for: record.origin).standardizedFileURL
        let parent = record.directoryURL.deletingLastPathComponent().standardizedFileURL
        guard parent == expectedRoot else { throw ReadingSessionArchiveError.invalidSessionDirectory }
        try FileManager.default.removeItem(at: record.directoryURL)
    }

    @discardableResult
    public func update(_ session: ReadingSession, for record: ReadingSessionRecord) throws -> ReadingSessionRecord {
        guard session.id == record.id else { throw ReadingSessionArchiveError.invalidSessionDirectory }
        let expectedRoot = directory(for: record.origin).standardizedFileURL
        let parent = record.directoryURL.deletingLastPathComponent().standardizedFileURL
        guard parent == expectedRoot else { throw ReadingSessionArchiveError.invalidSessionDirectory }
        try ReadingSessionManifest.write(session, to: record.directoryURL)
        return ReadingSessionRecord(session: session, directoryURL: record.directoryURL, origin: record.origin)
    }

    private func loadRecord(at directoryURL: URL, origin: ReadingSessionOrigin) throws -> ReadingSessionRecord {
        let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true,
              UUID(uuidString: directoryURL.lastPathComponent) != nil
        else { throw ReadingSessionArchiveError.invalidSessionDirectory }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(
            ReadingSession.self,
            from: Data(contentsOf: directoryURL.appendingPathComponent("manifest.json"))
        )
        guard session.id.uuidString.caseInsensitiveCompare(directoryURL.lastPathComponent) == .orderedSame else {
            throw ReadingSessionArchiveError.invalidSessionDirectory
        }
        return ReadingSessionRecord(session: session, directoryURL: directoryURL, origin: origin)
    }

    private func directory(for origin: ReadingSessionOrigin) -> URL {
        switch origin {
        case .recent: recentDirectory
        case .archive: archiveDirectory
        }
    }

    public static func isSafeFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && fileName == URL(fileURLWithPath: fileName).lastPathComponent
            && !fileName.contains("/")
            && !fileName.contains(":")
    }
}
