@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import SwiftSpeechKit

// MARK: - ChunkedAudioPlayer.resolveSeekTarget

/// Constructs a placeholder `Entry` with a synthesized silent `AVAudioPlayer`
/// so unit tests can walk the resolveSeekTarget math without decoding a
/// real audio file. The `AVAudioPlayer` is required by the struct but is
/// never played by these tests.
@MainActor
private func makeChunkedEntry(duration: TimeInterval, chunkIndex: Int) -> ChunkedAudioPlayer.Entry {
    let sampleRate: Double = 22_050
    let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    // AVAudioPlayer requires a decodable container. Write a tiny CAF file
    // to a temp URL and load it back — CAF is a valid container that
    // AVAudioPlayer accepts and keeps the test on disk-free unit territory.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("speakflow-seek-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try! AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try! file.write(from: buffer)
    let data = try! Data(contentsOf: url)
    let player = try! AVAudioPlayer(data: data)
    return ChunkedAudioPlayer.Entry(player: player, chunkIndex: chunkIndex, duration: duration)
}

@MainActor
@Test func chunkedSeekResolvesWithinCurrentChunk() {
    let timeline = [
        makeChunkedEntry(duration: 3, chunkIndex: 0),
        makeChunkedEntry(duration: 4, chunkIndex: 1),
        makeChunkedEntry(duration: 5, chunkIndex: 2),
    ]
    let resolved = try! #require(ChunkedAudioPlayer.resolveSeekTarget(1.5, in: timeline))
    #expect(resolved.timelineIndex == 0)
    #expect(abs(resolved.offsetInChunk - 1.5) < 0.05)
}

@MainActor
@Test func chunkedSeekResolvesAcrossChunks() {
    let timeline = [
        makeChunkedEntry(duration: 3, chunkIndex: 0),
        makeChunkedEntry(duration: 4, chunkIndex: 1),
        makeChunkedEntry(duration: 5, chunkIndex: 2),
    ]
    // Target 5.0s: chunk 0 spans 0-3, chunk 1 spans 3-7. Target falls 2s
    // into chunk 1.
    let resolved = try! #require(ChunkedAudioPlayer.resolveSeekTarget(5.0, in: timeline))
    #expect(resolved.timelineIndex == 1)
    #expect(abs(resolved.offsetInChunk - 2.0) < 0.05)
}

@MainActor
@Test func chunkedSeekClampsPastFinalChunk() {
    let timeline = [
        makeChunkedEntry(duration: 3, chunkIndex: 0),
        makeChunkedEntry(duration: 4, chunkIndex: 1),
    ]
    let resolved = try! #require(ChunkedAudioPlayer.resolveSeekTarget(999, in: timeline))
    #expect(resolved.timelineIndex == 1)
    #expect(abs(resolved.offsetInChunk - 4) < 0.05)
}

@MainActor
@Test func chunkedSeekReturnsNilForEmptyTimeline() {
    #expect(ChunkedAudioPlayer.resolveSeekTarget(0, in: []) == nil)
}

@MainActor
@Test func chunkedSeekClampsNegativeTargetToStart() {
    let timeline = [
        makeChunkedEntry(duration: 3, chunkIndex: 0),
        makeChunkedEntry(duration: 4, chunkIndex: 1),
    ]
    let resolved = try! #require(ChunkedAudioPlayer.resolveSeekTarget(-5, in: timeline))
    #expect(resolved.timelineIndex == 0)
    #expect(resolved.offsetInChunk == 0)
}

// MARK: - SpeechPlayer approximate seek math

@MainActor
@Test func speechDefaultCharactersPerSecondScalesWithRateAndPlayback() {
    // At Apple's default rate and 1x playback the fallback is 15 cps.
    let baseDefault = SpeechPlayer.defaultCharactersPerSecond(
        baseRate: AVSpeechUtteranceDefaultSpeechRate,
        playbackRate: 1
    )
    #expect(abs(baseDefault - 15) < 0.001)

    // 1.5x playback should scale the estimate proportionally.
    let scaledPlayback = SpeechPlayer.defaultCharactersPerSecond(
        baseRate: AVSpeechUtteranceDefaultSpeechRate,
        playbackRate: 1.5
    )
    #expect(abs(scaledPlayback - 22.5) < 0.001)

    // A higher base rate should scale similarly — double the base rate
    // roughly doubles the estimate.
    let scaledRate = SpeechPlayer.defaultCharactersPerSecond(
        baseRate: AVSpeechUtteranceDefaultSpeechRate * 2,
        playbackRate: 1
    )
    #expect(abs(scaledRate - 30) < 0.001)
}

@MainActor
@Test func speechDefaultCharactersPerSecondHasFloor() {
    // A sub-minimum rate must still return a positive value so the seek
    // arithmetic never yields zero characters.
    let value = SpeechPlayer.defaultCharactersPerSecond(baseRate: 0, playbackRate: 0.1)
    #expect(value >= 1)
}

@MainActor
@Test func speechApproximateSeekOffsetClampsWithinTextBounds() {
    let text = "Hello there, world."
    #expect(SpeechPlayer.approximateSeekOffset(from: 5, deltaCharacters: -100, in: text) == 0)
    #expect(SpeechPlayer.approximateSeekOffset(from: 5, deltaCharacters: 100, in: text) == text.utf16.count)
    #expect(SpeechPlayer.approximateSeekOffset(from: 5, deltaCharacters: 3, in: text) == 8)
}

@MainActor
@Test func speechRemainingTextSlicesFromUTF16Offset() {
    let text = "Hello there, world."
    let sliced = SpeechPlayer.remainingText(after: 7, in: text)
    #expect(sliced == "here, world.")
}

@MainActor
@Test func speechRemainingTextHandlesSurrogatePairs() {
    // A grinning face emoji occupies two UTF-16 units. Offset 5 lands at
    // the start of the emoji; offset 6 lands mid-surrogate and must round
    // forward to the character following the emoji rather than emitting a
    // malformed substring.
    let text = "Read 😀 the rest."
    let atEmoji = SpeechPlayer.remainingText(after: 5, in: text)
    #expect(atEmoji == "😀 the rest.")

    let midEmoji = SpeechPlayer.remainingText(after: 6, in: text)
    #expect(midEmoji == " the rest.")
}

@MainActor
@Test func speechRemainingTextReturnsNilPastEnd() {
    let text = "Short."
    #expect(SpeechPlayer.remainingText(after: text.utf16.count, in: text) == nil)
    #expect(SpeechPlayer.remainingText(after: text.utf16.count + 10, in: text) == nil)
}

// MARK: - ChunkedAudioPlayer canSeek gating

@MainActor
@Test func chunkedAudioPlayerReportsNoSeekWhenIdle() {
    let player = ChunkedAudioPlayer()
    #expect(!player.canSeek)
    #expect(player.testing_historyCount == 0)
    #expect(player.testing_queueCount == 0)
    #expect(player.testing_currentChunkIndex == nil)
}
