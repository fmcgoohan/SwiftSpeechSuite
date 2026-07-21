@preconcurrency import AVFAudio
import Foundation

/// Events the queue player reports to its driver (LocalVoiceEngine).
public enum ChunkedPlaybackEvent: Sendable, Equatable {
    case chunkStarted(index: Int)
    case chunkFinished(index: Int)
    /// Audible dead air: a chunk finished with nothing queued and no
    /// end-of-utterance mark, and the next chunk arrived `seconds` later.
    case underrun(seconds: TimeInterval)
    case utteranceFinished
    /// A `seek(by:)` landed inside `chunkIndex` at `offsetInChunk` seconds.
    /// The driver uses this to update its `ReadingSession` checkpoint so
    /// archive continuation reflects the current listening position.
    case seeked(chunkIndex: Int, offsetInChunk: TimeInterval)
}

/// Injectable seam so LocalVoiceEngine's tests can drive playback events
/// without real audio — same philosophy as SFLocalVoice's
/// URLRequestPerforming/FakePerformer.
@MainActor
public protocol ChunkedAudioPlaying: AnyObject {
    var state: SpeechState { get }
    var queuedChunkCount: Int { get }
    var onEvent: (@MainActor (ChunkedPlaybackEvent) -> Void)? { get set }
    /// True when there is any retained or in-flight chunk to seek across.
    var canSeek: Bool { get }
    /// Decodes and queues one complete audio file; starts playback if
    /// nothing is playing (and not paused). Returns the chunk's duration.
    @discardableResult
    func enqueue(data: Data) throws -> TimeInterval
    /// No more chunks are coming — after the queue drains, emit
    /// `.utteranceFinished` and go idle instead of waiting for more.
    func markEndOfUtterance()
    func pause()
    func resume()
    func stop()
    func setPlaybackRate(_ rate: Float)
    /// Seek playback by `offset` seconds relative to the current position,
    /// walking retained history for rewinds and the queued-but-unplayed
    /// chunks for fast-forwards. Clamped at the boundaries of the audio
    /// that has actually been produced.
    func seek(by offset: TimeInterval)
}

/// Plays a sequence of separately-synthesized audio chunks back-to-back —
/// AudioFilePlayer's queue-aware sibling (that one stays single-shot for
/// ElevenLabs; the gap/underrun/end-mark semantics here are a genuinely
/// different contract, not a superset worth merging).
@MainActor
public final class ChunkedAudioPlayer: NSObject, ObservableObject, ChunkedAudioPlaying {
    /// Retained played chunks are capped to this count so long reads
    /// don't grow the process's audio-decoder resident set unboundedly.
    /// Kokoro sentence chunks are typically 3-6 s of audio, so 32 keeps
    /// roughly two minutes of rewindable material without spilling into
    /// pathological retention.
    public static let historyChunkLimit = 32

    /// Bundles the `AVAudioPlayer` with its chunk index and duration so
    /// history, current, and queued state can be walked as one ordered
    /// timeline during a seek.
    struct Entry {
        let player: AVAudioPlayer
        let chunkIndex: Int
        let duration: TimeInterval
    }

    @Published public private(set) var state: SpeechState = .idle
    public var onEvent: (@MainActor (ChunkedPlaybackEvent) -> Void)?

    private var queue: [Entry] = []
    private var current: Entry?
    /// Played chunks retained oldest-first for backward seek. Capped by
    /// `historyChunkLimit`; older entries fall off the front.
    private var history: [Entry] = []
    private var endMarked = false
    private var nextChunkIndex = 0
    private var waitingSince: ContinuousClock.Instant?
    private var playbackRate: Float = 1

    public var queuedChunkCount: Int { queue.count }

    /// True whenever there is any chunk to seek within — current, queued
    /// forward, or retained history.
    public var canSeek: Bool {
        current != nil || !history.isEmpty || !queue.isEmpty
    }

    override public init() {
        super.init()
    }

    @discardableResult
    public func enqueue(data: Data) throws -> TimeInterval {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.enableRate = true
        player.rate = playbackRate
        let entry = Entry(player: player, chunkIndex: nextChunkIndex, duration: player.duration)
        nextChunkIndex += 1
        queue.append(entry)

        if let waitingSince {
            let gap = waitingSince.duration(to: .now)
            let seconds = Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18
            onEvent?(.underrun(seconds: seconds))
            self.waitingSince = nil
        }
        if current == nil, state != .paused {
            playNext()
        }
        return player.duration
    }

    public func markEndOfUtterance() {
        endMarked = true
        // Everything may have already drained while synthesis of a
        // never-sent chunk was still deciding — finish now if so.
        if current == nil, queue.isEmpty, state != .idle {
            finishUtterance()
        }
    }

    public func pause() {
        // Also honored from .idle: the driver can pause BEFORE the first
        // chunk arrives (user paused during synthesis) — enqueue() checks
        // `state != .paused` and holds the chunk instead of auto-starting.
        guard state == .speaking || state == .idle else { return }
        current?.player.pause() // nil between chunks — .paused alone stops auto-advance
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        if let current {
            current.player.play()
            state = .speaking
        } else {
            state = .speaking
            playNext() // was paused between chunks
        }
    }

    public func stop() {
        current?.player.stop()
        current = nil
        queue.removeAll()
        history.removeAll()
        endMarked = false
        waitingSince = nil
        nextChunkIndex = 0
        state = .idle
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = PlaybackRate.normalized(rate)
        if let current {
            current.player.enableRate = true
            current.player.rate = playbackRate
        }
        for entry in queue {
            entry.player.enableRate = true
            entry.player.rate = playbackRate
        }
    }

    public func seek(by offset: TimeInterval) {
        guard canSeek, offset.isFinite, offset != 0 else { return }
        let wasPaused = state == .paused
        let timeline = history + (current.map { [$0] } ?? []) + queue
        let currentPosition = history.reduce(0) { $0 + $1.duration } + (current?.player.currentTime ?? 0)
        let totalDuration = timeline.reduce(0) { $0 + $1.duration }
        let target = min(max(currentPosition + offset, 0), totalDuration)
        guard let resolved = Self.resolveSeekTarget(target, in: timeline) else { return }

        // Stop the currently-playing chunk before repartitioning; a stray
        // `audioPlayerDidFinishPlaying` from this cancellation would be
        // handled by `chunkDidFinish` which is safe (see comment there).
        current?.player.stop()

        // Repartition around the resolved index. Everything before the
        // target chunk becomes history (respecting the cap), the target
        // chunk becomes current, and everything after remains queued.
        history = Array(timeline.prefix(resolved.timelineIndex))
        trimHistory()
        let targetEntry = timeline[resolved.timelineIndex]
        targetEntry.player.currentTime = min(
            max(resolved.offsetInChunk, 0),
            targetEntry.duration
        )
        targetEntry.player.enableRate = true
        targetEntry.player.rate = playbackRate
        current = targetEntry
        queue = Array(timeline.dropFirst(resolved.timelineIndex + 1))
        for entry in queue {
            entry.player.stop()
            entry.player.currentTime = 0
            entry.player.enableRate = true
            entry.player.rate = playbackRate
        }
        waitingSince = nil

        if wasPaused {
            state = .paused
        } else {
            state = .speaking
            targetEntry.player.play()
        }

        onEvent?(.seeked(chunkIndex: targetEntry.chunkIndex, offsetInChunk: targetEntry.player.currentTime))
    }

    /// Resolves an absolute target position (in seconds from the start of
    /// the timeline) to the containing chunk and intra-chunk offset. This
    /// pure-math helper is exercised directly by SFSpeechTests without an
    /// audio device.
    struct ResolvedSeek: Equatable {
        let timelineIndex: Int
        let offsetInChunk: TimeInterval
    }

    static func resolveSeekTarget(_ target: TimeInterval, in timeline: [Entry]) -> ResolvedSeek? {
        guard !timeline.isEmpty else { return nil }
        let clamped = max(target, 0)
        var cumulative: TimeInterval = 0
        for (index, entry) in timeline.enumerated() {
            let end = cumulative + entry.duration
            let isLast = index == timeline.count - 1
            if clamped < end || (isLast && clamped <= end) {
                return ResolvedSeek(
                    timelineIndex: index,
                    offsetInChunk: max(0, min(clamped - cumulative, entry.duration))
                )
            }
            cumulative = end
        }
        // Target beyond timeline: clamp at end of last chunk.
        return ResolvedSeek(
            timelineIndex: timeline.count - 1,
            offsetInChunk: timeline[timeline.count - 1].duration
        )
    }

    private func trimHistory() {
        while history.count > Self.historyChunkLimit {
            history.removeFirst()
        }
    }

    private func playNext() {
        guard !queue.isEmpty else {
            if endMarked {
                finishUtterance()
            } else {
                waitingSince = .now // underrun starts; stay non-idle, more chunks coming
            }
            return
        }
        let entry = queue.removeFirst()
        current = entry
        entry.player.play()
        state = .speaking
        onEvent?(.chunkStarted(index: entry.chunkIndex))
    }

    private func finishUtterance() {
        current = nil
        endMarked = false
        waitingSince = nil
        nextChunkIndex = 0
        history.removeAll()
        state = .idle
        onEvent?(.utteranceFinished)
    }

    private func chunkDidFinish() {
        guard let finished = current else { return }
        current = nil
        // Move the finished chunk into retained history for future seeks.
        history.append(finished)
        trimHistory()
        onEvent?(.chunkFinished(index: finished.chunkIndex))
        guard state != .paused else { return } // hold until resume()
        playNext()
    }

    // Test hooks: SFSpeechTests can inspect internal state without
    // needing to spin up a real audio device.
    var testing_historyCount: Int { history.count }
    var testing_queueCount: Int { queue.count }
    var testing_currentChunkIndex: Int? { current?.chunkIndex }
}

extension ChunkedAudioPlayer: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.chunkDidFinish() }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.chunkDidFinish() } // skip the bad chunk, keep the read going
    }
}
