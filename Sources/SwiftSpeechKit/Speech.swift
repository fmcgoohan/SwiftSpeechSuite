@preconcurrency import AVFAudio
import Foundation
import SwiftLogKit

/// AVSpeechSynthesizer playback state.
public enum SpeechState: Sendable, Equatable {
    case idle
    case speaking
    case paused
}

public enum SpeechPlaybackEvent: Sendable, Equatable {
    case progress(characterOffset: Int, totalCharacters: Int)
    case paused
    case resumed
    case finished
    case stopped
}

@MainActor
public final class SpeechPlayer: NSObject, ObservableObject {
    /// Defensive cap: observed in practice (see project notes) that Apple's
    /// on-device TTS engine can wedge indefinitely — pegging a CPU core in
    /// its own internal string processing and never calling back — on some
    /// inputs. Capping length bounds the blast radius; the watchdog below
    /// is what actually recovers the app if it happens anyway.
    private static let maxCharacters = 20_000

    @Published public private(set) var state: SpeechState = .idle
    public var onEvent: (@MainActor (SpeechPlaybackEvent) -> Void)?

    private let synthesizer = AVSpeechSynthesizer() // long-lived, owned by the app —
    // avoids the ARC-lifetime gotcha Selftest.swift hit with a one-shot local instance.
    private var watchdogTask: Task<Void, Never>?
    private var generation = 0
    private var playbackRate: Float = 1
    private var activeTextLength = 0

    /// Retained utterance context so `seek(by:)` can re-`speak` the
    /// remainder from an approximated text offset. `AVSpeechSynthesizer`
    /// cannot retime an in-flight utterance, so this is the platform
    /// limitation the backlog calls out; a text-offset approximation is
    /// the closest usable rewind/forward primitive Apple exposes.
    private var activeText = ""
    private var activeVoiceIdentifier: String?
    private var activeLanguageCode: String?
    private var activeBaseRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var activePitch: Float = 1
    private var activeVolume: Float = 1
    /// Last UTF-16 offset reported by `willSpeakRangeOfSpeechString`.
    /// The delegate emits ranges in UTF-16 units, matching `activeText.utf16`.
    private var lastReportedCharacterOffset = 0
    /// Start of the currently-active utterance. Used to measure a
    /// per-utterance characters-per-second sample the seek converter can
    /// then invert.
    private var activeStartTime: ContinuousClock.Instant?
    /// Smoothed characters-per-second, updated on each range progress
    /// event. Zero until at least one boundary has been observed.
    private var measuredCharactersPerSecond: Double = 0

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(
        _ text: String,
        rate: Float,
        pitch: Float,
        volume: Float,
        voiceIdentifier: String?,
        languageCode: String? = nil
    ) {
        guard !text.isEmpty else { return }
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let bounded = text.count > Self.maxCharacters ? String(text.prefix(Self.maxCharacters)) : text
        activeTextLength = bounded.utf16.count
        activeText = bounded
        activeVoiceIdentifier = voiceIdentifier
        activeLanguageCode = languageCode
        activeBaseRate = rate
        activePitch = pitch
        activeVolume = volume
        lastReportedCharacterOffset = 0
        measuredCharactersPerSecond = 0
        activeStartTime = .now

        generation += 1
        let myGeneration = generation

        let utterance = AVSpeechUtterance(string: bounded)
        utterance.rate = min(
            max(rate * playbackRate, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        let preferredVoice = voiceIdentifier
            .flatMap(AVSpeechSynthesisVoice.init(identifier:))
            .flatMap { Self.voice($0, matches: languageCode) ? $0 : nil }
        utterance.voice = preferredVoice ?? Self.bestAvailableVoice(languageCode: languageCode)
        synthesizer.speak(utterance)
        state = .speaking
        armWatchdog(for: myGeneration, textLength: bounded.count)
    }

    public func pause() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
    }

    public func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
    }

    public func stop() {
        watchdogTask?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        clearActiveUtterance()
        state = .idle
        onEvent?(.stopped)
    }

    /// True when there is a paused or in-flight utterance whose retained
    /// text and last-reported UTF-16 offset can drive an approximate
    /// re-`speak` from a new offset. `AVSpeechSynthesizer` cannot retime
    /// an in-flight utterance, so this is a text-offset approximation
    /// rather than an audio-accurate seek — the closest primitive Apple
    /// exposes on macOS.
    public var canSeek: Bool {
        state != .idle && !activeText.isEmpty
    }

    /// Approximate seek: convert `offset` seconds to a character delta
    /// using the observed (or defaulted) characters-per-second rate,
    /// slice `activeText` from the new UTF-16 offset, and re-`speak` the
    /// remainder using the same voice, base rate, pitch, volume, and
    /// language. Landing mid-grapheme is rounded forward to the next
    /// character boundary so we never emit an invalid Swift substring.
    public func seek(by offset: TimeInterval) {
        guard canSeek, offset.isFinite, offset != 0 else { return }
        let cps = charactersPerSecondEstimate()
        let deltaChars = Int((offset * cps).rounded())
        let text = activeText
        let newOffset = Self.approximateSeekOffset(
            from: lastReportedCharacterOffset,
            deltaCharacters: deltaChars,
            in: text
        )
        guard let remainder = Self.remainingText(after: newOffset, in: text), !remainder.isEmpty else {
            // Seek walked past the tail: mirror natural end-of-utterance.
            stop()
            return
        }
        let savedVoice = activeVoiceIdentifier
        let savedLanguage = activeLanguageCode
        let savedRate = activeBaseRate
        let savedPitch = activePitch
        let savedVolume = activeVolume
        SFLog.pipeline.notice(
            "speech seek: offset \(offset, privacy: .public)s (~\(deltaChars, privacy: .public) chars at \(cps, privacy: .public) cps)"
        )
        // `speak` internally stops any current utterance and resets state.
        speak(
            remainder,
            rate: savedRate,
            pitch: savedPitch,
            volume: savedVolume,
            voiceIdentifier: savedVoice,
            languageCode: savedLanguage
        )
    }

    private func clearActiveUtterance() {
        activeText = ""
        activeTextLength = 0
        activeVoiceIdentifier = nil
        activeLanguageCode = nil
        activeStartTime = nil
        lastReportedCharacterOffset = 0
        measuredCharactersPerSecond = 0
    }

    /// Best available characters-per-second estimate. Prefers the observed
    /// rate from the current utterance's boundary events; falls back to a
    /// speech-rate-adjusted default when nothing has been measured yet.
    private func charactersPerSecondEstimate() -> Double {
        if measuredCharactersPerSecond > 0 { return measuredCharactersPerSecond }
        return Self.defaultCharactersPerSecond(baseRate: activeBaseRate, playbackRate: playbackRate)
    }

    /// Apple's default rate (0.5) sounds at roughly 15 chars/sec. The
    /// synthesizer's actual output rate scales with `utterance.rate`, and
    /// SpeakFlow multiplies that by `playbackRate`, so the fallback scales
    /// the same way. Kept pure for direct unit testing.
    static func defaultCharactersPerSecond(baseRate: Float, playbackRate: Float) -> Double {
        let base = 15.0
        let rateScale = Double(baseRate) / Double(AVSpeechUtteranceDefaultSpeechRate)
        let playbackScale = Double(PlaybackRate.normalized(playbackRate))
        return max(1, base * rateScale * playbackScale)
    }

    /// Converts a character delta relative to the last reported UTF-16
    /// offset into a clamped absolute offset in `[0, text.utf16.count]`.
    /// Pure to keep the seek math directly testable.
    static func approximateSeekOffset(from currentOffset: Int, deltaCharacters: Int, in text: String) -> Int {
        let total = text.utf16.count
        let raw = currentOffset + deltaCharacters
        return min(max(raw, 0), total)
    }

    /// Returns the substring of `text` starting at UTF-16 `offset`,
    /// rounded forward to the next Character boundary so we never split
    /// a surrogate pair. Returns `nil` if the offset lands past the end.
    static func remainingText(after offset: Int, in text: String) -> String? {
        let utf16 = text.utf16
        let clamped = min(max(offset, 0), utf16.count)
        guard clamped < utf16.count else { return nil }
        guard let utf16Index = utf16.index(utf16.startIndex, offsetBy: clamped, limitedBy: utf16.endIndex) else {
            return nil
        }
        if let stringIndex = String.Index(utf16Index, within: text) {
            return String(text[stringIndex...])
        }
        // Landed mid-grapheme (surrogate pair or combining sequence): step
        // forward one UTF-16 unit at a time until we hit a Character start.
        var probe = utf16Index
        while probe < utf16.endIndex {
            probe = utf16.index(after: probe)
            if let stringIndex = String.Index(probe, within: text) {
                return String(text[stringIndex...])
            }
        }
        return nil
    }

    /// AVSpeechSynthesizer cannot retime an utterance already in flight.
    /// Store the shared preference here so it applies to the next read.
    public func setPlaybackRate(_ rate: Float) {
        playbackRate = PlaybackRate.normalized(rate)
    }

    /// Recovers from the engine-wedge case above: if an utterance hasn't
    /// finished within a generous, length-scaled budget, force-stop and
    /// reset to idle so the hotkey/menu keep responding instead of the app
    /// silently going unresponsive forever. The generation check ensures a
    /// stale watchdog from a prior utterance never cancels a newer one.
    private func armWatchdog(for myGeneration: Int, textLength: Int) {
        watchdogTask?.cancel()
        let timeoutSeconds = max(20.0, Double(textLength) / 5.0) // ~5 chars/sec worst case + floor
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == myGeneration, self.state != .idle else { return }
            SFLog.pipeline.error("speech watchdog: utterance did not finish within \(timeoutSeconds, privacy: .public)s — force-stopping a wedged engine")
            self.synthesizer.stopSpeaking(at: .immediate)
            self.state = .idle
        }
    }

    /// Prefers the highest-quality on-device voice available for the
    /// current system language — premium, then enhanced, then whatever
    /// default voice exists. SFDoctor separately flags when only a
    /// default-quality voice is installed.
    public static func bestAvailableVoice(languageCode: String? = nil) -> AVSpeechSynthesisVoice? {
        let languageCode = languageCode ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice($0, matches: languageCode) }
        let byQuality = candidates.sorted { $0.quality.rawValue > $1.quality.rawValue }
        return byQuality.first ?? AVSpeechSynthesisVoice(language: languageCode)
    }

    private static func voice(_ voice: AVSpeechSynthesisVoice, matches languageCode: String?) -> Bool {
        guard let languageCode else { return true }
        let requested = languageCode.replacingOccurrences(of: "_", with: "-").lowercased()
        let available = voice.language.replacingOccurrences(of: "_", with: "-").lowercased()
        if available == requested { return true }
        return available.split(separator: "-").first == requested.split(separator: "-").first
    }
}

extension SpeechPlayer: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            let endOffset = min(characterRange.location + characterRange.length, self.activeTextLength)
            self.lastReportedCharacterOffset = endOffset
            if let start = self.activeStartTime, endOffset > 0 {
                let elapsed = start.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if seconds > 0.5 {
                    self.measuredCharactersPerSecond = Double(endOffset) / seconds
                }
            }
            self.onEvent?(.progress(
                characterOffset: endOffset,
                totalCharacters: self.activeTextLength
            ))
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.watchdogTask?.cancel()
            self.clearActiveUtterance()
            self.state = .idle
            self.onEvent?(.finished)
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.watchdogTask?.cancel()
            // Do NOT clear active utterance state here — `seek(by:)`
            // cancels the in-flight utterance before re-`speak`ing, and
            // `speak` needs the retained voice/language context to be
            // available before it overwrites them. `speak()` reassigns
            // `activeText` etc. immediately, so no stale state remains.
            self.state = .idle
            self.onEvent?(.stopped)
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .paused
            self.onEvent?(.paused)
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .speaking
            self.onEvent?(.resumed)
        }
    }
}
