// swift-tools-version: 6.2
import PackageDescription

// SwiftSpeechSuite — reusable macOS building blocks for a read-aloud / TTS app,
// each exposed as its own library product so callers pull only what they need:
//
//   SwiftLogKit          os.Logger with an injectable subsystem
//   SwiftSpeechKit       AVFoundation players + PlaybackRate/chunking
//   SwiftReadingSession  session model, archive, deep-link continuation
//   SwiftGlobalHotkey    CGEvent-tap global hotkey manager
//   AXFocus / AXTextSource  Accessibility focus + captured-text reading
//   AppleTranslationKit  on-device Translation-framework coordinator
//   ElevenLabsSwift      ElevenLabs TTS client + Keychain store
//
// Platform floor is macOS 26 because AppleTranslationKit uses TranslationSession
// APIs introduced there; the accessibility and hotkey modules are macOS-only.
let package = Package(
    name: "SwiftSpeechSuite",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SwiftLogKit", targets: ["SwiftLogKit"]),
        .library(name: "SwiftSpeechKit", targets: ["SwiftSpeechKit"]),
        .library(name: "SwiftReadingSession", targets: ["SwiftReadingSession"]),
        .library(name: "SwiftGlobalHotkey", targets: ["SwiftGlobalHotkey"]),
        .library(name: "AXFocus", targets: ["AXFocus"]),
        .library(name: "AXTextSource", targets: ["AXTextSource"]),
        .library(name: "AppleTranslationKit", targets: ["AppleTranslationKit"]),
        .library(name: "ElevenLabsSwift", targets: ["ElevenLabsSwift"]),
    ],
    targets: [
        .target(name: "SwiftLogKit"),
        .target(name: "SwiftSpeechKit", dependencies: ["SwiftLogKit"]),
        .target(name: "SwiftReadingSession", dependencies: ["SwiftSpeechKit"]),
        .target(name: "SwiftGlobalHotkey"),
        .target(name: "AXFocus"),
        .target(name: "AXTextSource", dependencies: ["AXFocus"]),
        .target(name: "AppleTranslationKit", dependencies: ["SwiftLogKit"]),
        .target(name: "ElevenLabsSwift"),

        .testTarget(name: "SwiftLogKitTests", dependencies: ["SwiftLogKit"]),
        .testTarget(name: "SwiftSpeechKitTests", dependencies: ["SwiftSpeechKit"]),
        .testTarget(name: "SwiftReadingSessionTests", dependencies: ["SwiftReadingSession"]),
        .testTarget(name: "SwiftGlobalHotkeyTests", dependencies: ["SwiftGlobalHotkey"]),
        .testTarget(name: "AXTextSourceTests", dependencies: ["AXFocus", "AXTextSource"]),
        .testTarget(name: "AppleTranslationKitTests", dependencies: ["AppleTranslationKit"]),
        .testTarget(name: "ElevenLabsSwiftTests", dependencies: ["ElevenLabsSwift"]),
    ]
)
