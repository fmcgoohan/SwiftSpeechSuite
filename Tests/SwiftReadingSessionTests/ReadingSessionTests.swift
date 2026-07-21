import Foundation
import SwiftSpeechKit
import Testing
@testable import SwiftReadingSession

@Test func readingSessionTracksGeneratedAndPlayedAudioBySegment() {
    let date = Date(timeIntervalSince1970: 100)
    var session = ReadingSession(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        createdAt: date,
        text: "First sentence. Second sentence.",
        backend: ReadingBackend("nativeMLX"),
        playbackRate: 1.5,
        segmentTexts: ["First sentence.", "Second sentence."]
    )

    session.recordGeneratedAudio(segmentIndex: 0, seconds: 3)
    session.recordPlayback(segmentIndex: 0, seconds: 1.25, at: date)
    #expect(session.checkpoint.segmentIndex == 0)
    #expect(session.checkpoint.audioSeconds == 1.25)

    session.markAudioComplete(segmentIndex: 0)
    session.markPlaybackComplete(segmentIndex: 0, at: date)
    #expect(session.segments[0].audioComplete)
    #expect(session.segments[0].playbackComplete)
    #expect(session.checkpoint.segmentIndex == 1)
    #expect(session.checkpoint.audioSeconds == 0)
}

@Test func readingSessionRoundTripsAsArchiveManifest() throws {
    let session = ReadingSession(
        text: "A portable research item.",
        backend: ReadingBackend("nativeMLX"),
        source: ReadingSource(
            applicationName: "Safari",
            title: "An Article",
            url: URL(string: "https://example.com/article")
        ),
        voiceName: "American Narrator",
        modelID: "qwen",
        segmentTexts: ["A portable research item."]
    )

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(ReadingSession.self, from: data)
    #expect(decoded == session)
}

@Test func translatedReadingSessionRoundTripsAndRetainsSourceText() throws {
    let translation = ReadingTranslation(
        sourceText: "Good morning.",
        sourceLanguageCode: "en",
        targetLanguageCode: "fr",
        translated: true
    )
    let session = ReadingSession(
        text: "Bonjour.",
        translation: translation,
        backend: ReadingBackend("onDevice"),
        segmentTexts: ["Bonjour."]
    )

    let decoded = try JSONDecoder().decode(
        ReadingSession.self,
        from: JSONEncoder().encode(session)
    )
    #expect(decoded.translation == translation)
    #expect(decoded.text == "Bonjour.")
}

@Test func playbackRateIsBoundedForEveryBackend() {
    #expect(PlaybackRate.normalized(0.1) == 0.75)
    #expect(PlaybackRate.normalized(1.5) == 1.5)
    #expect(PlaybackRate.normalized(4) == 2)
}

@Test func seekingPlaybackRebuildsCheckpointAndSegmentProgress() {
    var session = ReadingSession(
        text: "One. Two. Three.",
        backend: ReadingBackend("kokoroServer"),
        segmentTexts: ["One.", "Two.", "Three."]
    )
    for index in session.segments.indices {
        session.setGeneratedAudio(segmentIndex: index, seconds: 4)
        session.markAudioComplete(segmentIndex: index)
    }

    session.seekPlayback(segmentIndex: 1, audioSeconds: 1.5)

    #expect(session.segments[0].playbackComplete)
    #expect(session.segments[0].playedAudioSeconds == 4)
    #expect(!session.segments[1].playbackComplete)
    #expect(session.segments[1].playedAudioSeconds == 1.5)
    #expect(session.segments[2].playedAudioSeconds == 0)
    #expect(session.checkpoint.segmentIndex == 1)
    #expect(session.checkpoint.audioSeconds == 1.5)
}

@Test func textOnlySessionReportsProgressWithoutGeneratedAudio() {
    var session = ReadingSession(
        text: "A text-only on-device reading.",
        backend: ReadingBackend("onDevice"),
        audioFileExtension: nil,
        segmentTexts: ["A text-only on-device reading."]
    )
    session.seekText(to: session.text.count / 2)
    let record = ReadingSessionRecord(
        session: session,
        directoryURL: FileManager.default.temporaryDirectory,
        origin: .recent
    )

    #expect(record.progress > 0.45)
    #expect(record.progress < 0.55)
    #expect(session.segments[0].audioFileName == nil)
}

@Test func sessionPackageAndArchiveUpdatePersistBufferedAudioCheckpoint() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("speakflow-package-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recent = root.appendingPathComponent("recent", isDirectory: true)
    let archived = root.appendingPathComponent("archive", isDirectory: true)
    var session = ReadingSession(
        text: "Buffered audio.",
        backend: ReadingBackend("elevenLabs"),
        audioFileExtension: "mp3",
        segmentTexts: ["Buffered audio."]
    )
    let package = try ReadingSessionPackage(sessionID: session.id, baseDirectory: recent)
    try await package.writeAudio(Data("encoded-audio".utf8), fileName: "0000.mp3")
    session.setGeneratedAudio(segmentIndex: 0, seconds: 10)
    session.markAudioComplete(segmentIndex: 0)
    session.status = .stopped
    try package.persist(session)

    let store = ReadingSessionArchive(recentDirectory: recent, archiveDirectory: archived)
    let record = try #require(store.records(origin: .recent).first)
    #expect(record.audioURLs.map(\.lastPathComponent) == ["0000.mp3"])

    session.seekPlayback(segmentIndex: 0, audioSeconds: 6)
    let updated = try store.update(session, for: record)
    #expect(updated.progress == 0.6)
    #expect(try store.records(origin: .recent).first?.session.checkpoint.audioSeconds == 6)
}

@Test func pageAudioRecordPreservesOriginalMediaURL() throws {
    var session = ReadingSession(
        text: "Publisher article.",
        backend: ReadingBackend("pageAudio"),
        audioFileExtension: nil,
        segmentTexts: ["Publisher article."]
    )
    let mediaURL = try #require(URL(string: "https://example.com/article.mp3"))
    session.setRemoteAudioURL(mediaURL, segmentIndex: 0)
    let record = ReadingSessionRecord(
        session: session,
        directoryURL: FileManager.default.temporaryDirectory,
        origin: .recent
    )

    #expect(record.audioItems == [ReadingSessionAudioItem(segmentIndex: 0, url: mediaURL)])
}

@Test func continuationURLRoundTripsWithoutEmbeddingReadingText() throws {
    let request = ReadingContinuationRequest(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
        origin: .archive
    )
    let parsed = try #require(ReadingContinuationRequest(url: request.url))

    #expect(parsed == request)
    #expect(request.url.absoluteString.contains("session="))
    #expect(!request.url.absoluteString.contains("reading"))
    #expect(ReadingContinuationRequest(url: URL(string: "https://example.com")!) == nil)
}

@Test func segmentedContinuationStartsAtFirstIncompleteSynthesisBoundary() {
    var session = ReadingSession(
        text: "First. Second. Third.",
        backend: ReadingBackend("nativeMLX"),
        segmentTexts: ["First.", "Second.", "Third."]
    )
    session.markAudioComplete(segmentIndex: 0)
    session.recordGeneratedAudio(segmentIndex: 1, seconds: 0.5)

    #expect(session.synthesisContinuationText(strategy: .segmentBoundary) == "Second. Third.")

    session.markAudioComplete(segmentIndex: 1)
    session.markAudioComplete(segmentIndex: 2)
    #expect(session.synthesisContinuationText(strategy: .segmentBoundary) == nil)
}

@Test func onDeviceContinuationUsesUTF16Checkpoint() {
    var session = ReadingSession(
        text: "Read 😀 the remainder.",
        backend: ReadingBackend("onDevice"),
        audioFileExtension: nil,
        segmentTexts: ["Read 😀 the remainder."]
    )
    let prefix = "Read 😀 "
    session.seekText(to: prefix.utf16.count)

    #expect(session.synthesisContinuationText(strategy: .textOffset) == "the remainder.")
}

@Test func bufferedAndPublisherBackendsDoNotRegenerateCompletedMedia() {
    let elevenLabs = ReadingSession(
        text: "Already synthesized.",
        backend: ReadingBackend("elevenLabs"),
        segmentTexts: ["Already synthesized."]
    )
    let pageAudio = ReadingSession(
        text: "Publisher recording.",
        backend: ReadingBackend("pageAudio"),
        segmentTexts: ["Publisher recording."]
    )

    #expect(elevenLabs.synthesisContinuationText(strategy: .none) == nil)
    #expect(pageAudio.synthesisContinuationText(strategy: .none) == nil)
}

@Test func readingBackendEncodesAsBareStringForWireCompatibility() throws {
    // The pre-0.2 model stored `backend` as a String-backed enum, so it must
    // still encode/decode as a bare JSON string, not `{"rawValue": …}`.
    let data = try JSONEncoder().encode(ReadingBackend("nativeMLX"))
    #expect(String(data: data, encoding: .utf8) == "\"nativeMLX\"")
    #expect(try JSONDecoder().decode(ReadingBackend.self, from: data) == ReadingBackend("nativeMLX"))

    // A whole session round-trips, and a hand-written 0.1.x manifest snippet
    // with a bare backend string still decodes.
    let session = ReadingSession(
        text: "Hello.",
        backend: ReadingBackend("nativeMLX"),
        segmentTexts: ["Hello."]
    )
    let roundTripped = try JSONDecoder().decode(
        ReadingSession.self,
        from: JSONEncoder().encode(session)
    )
    #expect(roundTripped.backend == ReadingBackend("nativeMLX"))
    #expect(String(data: try JSONEncoder().encode(session), encoding: .utf8)?
        .contains("\"backend\":\"nativeMLX\"") == true)
}

@Test func archiveDiscoversPromotesAndDeletesCompletedSessions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("speakflow-archive-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recent = root.appendingPathComponent("recent", isDirectory: true)
    let archived = root.appendingPathComponent("archived", isDirectory: true)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    let sessionDirectory = recent.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

    var session = ReadingSession(
        id: id,
        createdAt: Date(timeIntervalSince1970: 200),
        text: "A durable research reading.",
        backend: ReadingBackend("nativeMLX"),
        source: ReadingSource(applicationName: "Safari", title: "Research Notes"),
        segmentTexts: ["A durable research reading."]
    )
    session.status = .completed
    session.recordGeneratedAudio(segmentIndex: 0, seconds: 2)
    session.recordPlayback(segmentIndex: 0, seconds: 1, at: Date(timeIntervalSince1970: 201))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(session).write(to: sessionDirectory.appendingPathComponent("manifest.json"))
    try Data("audio".utf8).write(to: sessionDirectory.appendingPathComponent("0000.caf"))

    let store = ReadingSessionArchive(recentDirectory: recent, archiveDirectory: archived)
    let recentRecords = try store.records(origin: .recent)
    #expect(recentRecords.count == 1)
    #expect(recentRecords[0].title == "Research Notes")
    #expect(recentRecords[0].progress == 0.5)
    #expect(recentRecords[0].audioURLs.count == 1)

    let saved = try store.archive(recentRecords[0])
    #expect(saved.origin == .archive)
    #expect(saved.session == session)
    #expect(saved.audioURLs.count == 1)
    #expect(try store.records(origin: .archive).map(\.id) == [id])

    try store.delete(saved)
    #expect(try store.records(origin: .archive).isEmpty)
}

@Test func archiveRejectsActiveAndMalformedSessions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("speakflow-archive-validation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recent = root.appendingPathComponent("recent", isDirectory: true)
    let archived = root.appendingPathComponent("archived", isDirectory: true)
    let id = UUID()
    let directory = recent.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let active = ReadingSession(
        id: id,
        text: "Still reading.",
        backend: ReadingBackend("nativeMLX"),
        segmentTexts: ["Still reading."]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(active).write(to: directory.appendingPathComponent("manifest.json"))
    try Data("escape".utf8).write(to: root.appendingPathComponent("escape.caf"))

    let store = ReadingSessionArchive(recentDirectory: recent, archiveDirectory: archived)
    let record = try #require(store.records(origin: .recent).first)
    #expect(throws: ReadingSessionArchiveError.sessionStillActive) {
        try store.archive(record)
    }

    let malformed = recent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: malformed.appendingPathComponent("manifest.json"))
    #expect(try store.records(origin: .recent).count == 1)
}
