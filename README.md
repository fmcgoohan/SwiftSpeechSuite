# SwiftSpeechSuite

[![CI](https://github.com/fmcgoohan/SwiftSpeechSuite/actions/workflows/ci.yml/badge.svg)](https://github.com/fmcgoohan/SwiftSpeechSuite/actions/workflows/ci.yml)
![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Reusable macOS building blocks for a read-aloud / text-to-speech app. Each
module is its own library product, so you depend on only what you need.

| Product | What it gives you |
|---|---|
| `SwiftLogKit` | `os.Logger` channels with an injectable subsystem (`SFLog.subsystem`, or the `LogKit(subsystem:)` value type). |
| `SwiftSpeechKit` | Apple on-device TTS (`SpeechPlayer`), single-shot (`AudioFilePlayer`) and streaming (`ChunkedAudioPlayer`) playback, sentence-aware chunking, and the shared `PlaybackRate` clamp. |
| `SwiftReadingSession` | The persisted model for a "reading": segmented text, independent audio/text checkpoints, on-disk session packaging, an archive of completed readings, and deep-link continuation. Storage containers and the URL scheme are injectable. |
| `SwiftGlobalHotkey` | A system-wide hotkey manager built on a CGEvent tap, with a protocol seam for testing. |
| `AXFocus` / `AXTextSource` | Read the user's focused/selected text via the Accessibility API, with a clipboard fallback and click-anchor tracking. |
| `ElevenLabsSwift` | A small ElevenLabs TTS client plus a Keychain-backed credential store; HTTP transport is injectable for testing. |

## Requirements

macOS 13+ for `SwiftLogKit`, `SwiftSpeechKit`, `SwiftReadingSession`, and
`ElevenLabsSwift` (which also build on iOS 16+); `SwiftGlobalHotkey` and
`AXFocus`/`AXTextSource` use Carbon/AppKit and are macOS-only. (The on-device
translation coordinator moved to [AppleTranslationKit](https://github.com/fmcgoohan/AppleTranslationKit).)

## Installation

```swift
.package(url: "https://github.com/fmcgoohan/SwiftSpeechSuite.git", from: "0.3.0")
```

Then add only the products you use, e.g.:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "SwiftSpeechKit", package: "SwiftSpeechSuite"),
    .product(name: "SwiftReadingSession", package: "SwiftSpeechSuite"),
])
```

## Usage

One short example per product.

### SwiftLogKit

```swift
import SwiftLogKit

let log = LogKit(subsystem: "com.example.myapp")
log.pipeline.notice("started")
// or the shared channels: SFLog.subsystem = "com.example.myapp"; SFLog.pipeline.notice("hi")
```

### SwiftSpeechKit

```swift
import SwiftSpeechKit

let player = SpeechPlayer()
player.setPlaybackRate(PlaybackRate.normalized(1.5))
player.speak("Hello from SpeakFlow", rate: 0.5, pitch: 1, volume: 1, voiceIdentifier: nil)

let chunks = SpeechTextChunker.chunk(longText, firstTarget: 350, target: 600, hardSplitLimit: 800)
```

### SwiftReadingSession

```swift
import SwiftReadingSession

extension ReadingBackend { static let myTTS = ReadingBackend("myTTS") }

var session = ReadingSession(text: "First. Second.", backend: .myTTS,
                            segmentTexts: ["First.", "Second."])
session.markAudioComplete(segmentIndex: 0)

// Resume policy is the caller's: pick a strategy per backend.
let remaining = session.synthesisContinuationText(strategy: .segmentBoundary)
```

### SwiftGlobalHotkey

```swift
import SwiftGlobalHotkey

let manager = CGEventTapHotkeyManager(variants: [
    HotkeyVariant(requiredModifierKeyCodes: []) { print("read-aloud hotkey!") }
])
_ = manager.start() // false if Accessibility/Input Monitoring isn't granted
```

### AXFocus / AXTextSource

```swift
import AXFocus

if let target = await FocusCapture.captureFocusTarget() {
    print(target)   // focused element's app, selected/field text, etc.
}
```

### ElevenLabsSwift

```swift
import ElevenLabsSwift

try ElevenLabsCredentialStore.save(apiKey)             // Keychain
let client = ElevenLabsClient(apiKey: ElevenLabsCredentialStore.load()!)
let audio = try await client.synthesize(text: "Hello", voiceId: voice, modelId: model)
```

## Branding the injectable defaults

Each module defaults to a neutral identity; override once at launch:

```swift
SFLog.subsystem = "com.example.myapp"
ElevenLabsCredentialStore.service = "com.example.myapp.elevenlabs"
ReadingSessionLocations.recentSessionsContainer = "MyApp"
ReadingSessionLocations.archiveContainer = "MyAppArchive"
ReadingContinuationRequest.scheme = "myapp"
```

## Documentation

Rendered API docs (DocC) for every product:
**https://fmcgoohan.github.io/SwiftSpeechSuite/documentation/**

Built from source doc comments and published to GitHub Pages by
`.github/workflows/docs.yml` on every push to `main`.

## License

MIT — see [LICENSE](LICENSE).
