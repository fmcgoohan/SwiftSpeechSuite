import Foundation
import SwiftSpeechKit

/// Identifies the engine that produced a reading. An open string identifier
/// rather than a closed enum, so each app names its own backends via a
/// `static let` extension (e.g. `ReadingBackend("nativeMLX")`) without this
/// package enumerating any one app's engines.
public struct ReadingBackend: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    // Encode as a bare string (not `{"rawValue": …}`) so manifests stay
    // wire-compatible with the previous `String`-backed enum.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ReadingSessionStatus: String, Codable, Sendable, Equatable {
    case reading
    case paused
    case stopped
    case completed
}

public struct ReadingTranslation: Codable, Sendable, Equatable {
    public let sourceText: String
    public let sourceLanguageCode: String
    public let targetLanguageCode: String
    public let provider: String
    public let translated: Bool

    public init(
        sourceText: String,
        sourceLanguageCode: String,
        targetLanguageCode: String,
        provider: String = "apple-on-device",
        translated: Bool = true
    ) {
        self.sourceText = sourceText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.provider = provider
        self.translated = translated
    }
}

public struct ReadingSource: Codable, Sendable, Equatable {
    public var applicationName: String?
    public var title: String?
    public var url: URL?

    public init(applicationName: String? = nil, title: String? = nil, url: URL? = nil) {
        self.applicationName = applicationName
        self.title = title
        self.url = url
    }
}

public struct ReadingSegment: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public var audioFileName: String?
    public var remoteAudioURL: URL?
    public var generatedAudioSeconds: TimeInterval
    public var playedAudioSeconds: TimeInterval
    public var audioComplete: Bool
    public var playbackComplete: Bool

    public init(
        id: Int,
        text: String,
        audioFileName: String? = nil,
        remoteAudioURL: URL? = nil
    ) {
        self.id = id
        self.text = text
        self.audioFileName = audioFileName
        self.remoteAudioURL = remoteAudioURL
        self.generatedAudioSeconds = 0
        self.playedAudioSeconds = 0
        self.audioComplete = false
        self.playbackComplete = false
    }
}

public struct ReadingCheckpoint: Codable, Sendable, Equatable {
    public var segmentIndex: Int
    public var audioSeconds: TimeInterval
    public var textOffset: Int?
    public var updatedAt: Date

    public init(
        segmentIndex: Int = 0,
        audioSeconds: TimeInterval = 0,
        textOffset: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.segmentIndex = segmentIndex
        self.audioSeconds = audioSeconds
        self.textOffset = textOffset
        self.updatedAt = updatedAt
    }
}

/// Shared state for the menu-bar reader now and the archive companion later.
/// Audio is checkpointed independently from text because generated speech has
/// no trustworthy word alignment until a dedicated aligner is introduced.
public struct ReadingSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public let translation: ReadingTranslation?
    public let backend: ReadingBackend
    public var source: ReadingSource
    public var voiceName: String?
    public var modelID: String?
    public var continuedFromSessionID: UUID?
    public var playbackRate: Float
    public var status: ReadingSessionStatus
    public var segments: [ReadingSegment]
    public var checkpoint: ReadingCheckpoint

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        text: String,
        translation: ReadingTranslation? = nil,
        backend: ReadingBackend,
        source: ReadingSource = ReadingSource(),
        voiceName: String? = nil,
        modelID: String? = nil,
        continuedFromSessionID: UUID? = nil,
        playbackRate: Float = 1,
        audioFileExtension: String? = "caf",
        segmentTexts: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.translation = translation
        self.backend = backend
        self.source = source
        self.voiceName = voiceName
        self.modelID = modelID
        self.continuedFromSessionID = continuedFromSessionID
        self.playbackRate = PlaybackRate.normalized(playbackRate)
        self.status = .reading
        self.segments = segmentTexts.enumerated().map { index, text in
            ReadingSegment(
                id: index,
                text: text,
                audioFileName: audioFileExtension.map { String(format: "%04d.%@", index, $0) }
            )
        }
        self.checkpoint = ReadingCheckpoint()
    }

    public mutating func recordGeneratedAudio(segmentIndex: Int, seconds: TimeInterval) {
        guard segments.indices.contains(segmentIndex) else { return }
        segments[segmentIndex].generatedAudioSeconds += max(0, seconds)
    }

    public mutating func setGeneratedAudio(segmentIndex: Int, seconds: TimeInterval) {
        guard segments.indices.contains(segmentIndex) else { return }
        segments[segmentIndex].generatedAudioSeconds = max(0, seconds)
    }

    public mutating func setRemoteAudioURL(_ url: URL, segmentIndex: Int) {
        guard segments.indices.contains(segmentIndex) else { return }
        segments[segmentIndex].remoteAudioURL = url
        segments[segmentIndex].audioFileName = nil
    }

    public mutating func markAudioComplete(segmentIndex: Int) {
        guard segments.indices.contains(segmentIndex) else { return }
        segments[segmentIndex].audioComplete = true
    }

    public mutating func recordPlayback(segmentIndex: Int, seconds: TimeInterval, at date: Date = Date()) {
        guard segments.indices.contains(segmentIndex), !segments[segmentIndex].playbackComplete else { return }
        segments[segmentIndex].playedAudioSeconds = min(
            segments[segmentIndex].generatedAudioSeconds,
            segments[segmentIndex].playedAudioSeconds + max(0, seconds)
        )
        checkpoint = ReadingCheckpoint(
            segmentIndex: segmentIndex,
            audioSeconds: segments[segmentIndex].playedAudioSeconds,
            updatedAt: date
        )
    }

    public mutating func markPlaybackComplete(segmentIndex: Int, at date: Date = Date()) {
        guard segments.indices.contains(segmentIndex) else { return }
        segments[segmentIndex].playbackComplete = true
        segments[segmentIndex].playedAudioSeconds = segments[segmentIndex].generatedAudioSeconds
        let next = min(segmentIndex + 1, segments.count)
        checkpoint = ReadingCheckpoint(segmentIndex: next, audioSeconds: 0, updatedAt: date)
    }

    public mutating func seekPlayback(
        segmentIndex: Int,
        audioSeconds: TimeInterval,
        at date: Date = Date()
    ) {
        let boundedIndex = min(max(segmentIndex, 0), segments.count)
        for index in segments.indices {
            if index < boundedIndex {
                segments[index].playedAudioSeconds = segments[index].generatedAudioSeconds
                segments[index].playbackComplete = true
            } else if index == boundedIndex {
                segments[index].playedAudioSeconds = min(
                    max(audioSeconds, 0),
                    segments[index].generatedAudioSeconds
                )
                segments[index].playbackComplete = false
            } else {
                segments[index].playedAudioSeconds = 0
                segments[index].playbackComplete = false
            }
        }
        checkpoint = ReadingCheckpoint(
            segmentIndex: boundedIndex,
            audioSeconds: boundedIndex < segments.count ? max(audioSeconds, 0) : 0,
            updatedAt: date
        )
    }

    public mutating func seekText(to offset: Int, at date: Date = Date()) {
        checkpoint = ReadingCheckpoint(
            segmentIndex: 0,
            audioSeconds: 0,
            textOffset: min(max(offset, 0), text.utf16.count),
            updatedAt: date
        )
    }
}
