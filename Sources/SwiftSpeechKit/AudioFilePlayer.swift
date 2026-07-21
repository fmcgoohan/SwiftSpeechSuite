@preconcurrency import AVFAudio
import Foundation

public enum AudioFilePlaybackEvent: Sendable, Equatable {
    case progress(seconds: TimeInterval, duration: TimeInterval)
    case paused
    case resumed
    case finished
    case stopped
}

/// AVAudioPlayer-backed playback for pre-rendered audio bytes (ElevenLabs,
/// the local MLX voice, or anything else that returns a finished audio
/// file rather than driving synthesis directly) — shares SpeechState with
/// SpeechPlayer so the app presents one uniform surface regardless of
/// which engine is active. Originally written as ElevenLabs-specific
/// ("ElevenLabsPlayer") but had zero ElevenLabs-specific code in it, so it
/// moved here (rename only) once a second engine needed the exact same
/// thing rather than a copy-pasted near-duplicate.
///
/// No watchdog needed the way SpeechPlayer has one — this is decoding/
/// playing a known-length downloaded file, not driving a live
/// multi-threaded synthesis engine that can wedge; the network/process
/// leg's own timeout is the safeguard on that side.
@MainActor
public final class AudioFilePlayer: NSObject, ObservableObject {
    @Published public private(set) var state: SpeechState = .idle
    public var onEvent: (@MainActor (AudioFilePlaybackEvent) -> Void)?

    private var player: AVAudioPlayer?
    private var playbackRate: Float = 1
    private var progressTask: Task<Void, Never>?

    public var canSeek: Bool { player != nil && state != .idle }

    override public init() {
        super.init()
    }

    @discardableResult
    public func play(data: Data) throws -> TimeInterval {
        stop(notify: false)
        let newPlayer = try AVAudioPlayer(data: data)
        newPlayer.delegate = self
        newPlayer.enableRate = true
        newPlayer.rate = playbackRate
        player = newPlayer
        newPlayer.play()
        state = .speaking
        startProgressUpdates()
        return newPlayer.duration
    }

    public func pause() {
        guard state == .speaking else { return }
        player?.pause()
        progressTask?.cancel()
        progressTask = nil
        reportProgress()
        state = .paused
        onEvent?(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        player?.play()
        state = .speaking
        onEvent?(.resumed)
        startProgressUpdates()
    }

    public func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        let wasActive = state != .idle
        reportProgress()
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        state = .idle
        if notify, wasActive { onEvent?(.stopped) }
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = PlaybackRate.normalized(rate)
        player?.enableRate = true
        player?.rate = playbackRate
    }

    public func seek(by offset: TimeInterval) {
        guard let player, offset.isFinite else { return }
        player.currentTime = min(max(player.currentTime + offset, 0), player.duration)
        reportProgress()
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.reportProgress()
            }
        }
    }

    private func reportProgress() {
        guard let player else { return }
        onEvent?(.progress(seconds: player.currentTime, duration: player.duration))
    }

    private func finish(_ event: AudioFilePlaybackEvent) {
        reportProgress()
        progressTask?.cancel()
        progressTask = nil
        player = nil
        state = .idle
        onEvent?(event)
    }
}

extension AudioFilePlayer: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finish(.finished)
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.finish(.stopped)
        }
    }
}
