// swift-tools-version: 6.2
import PackageDescription

// SwiftSpeechSuite — reusable macOS building blocks for a read-aloud / TTS app,
// each exposed as its own library product so callers pull only what they need:
//
//   SwiftLogKit          os.Logger with an injectable subsystem
//   SwiftSpeechKit       AVFoundation players + PlaybackRate/chunking
//   SwiftReadingSession  session model, archive, deep-link continuation
//   SwiftGlobalHotkey    CGEvent-tap global hotkey manager  (macOS only)
//   AXFocus / AXTextSource  Accessibility focus + captured-text reading (macOS only)
//   ElevenLabsSwift      ElevenLabs TTS client + Keychain store
//
// SwiftLogKit, SwiftSpeechKit, SwiftReadingSession, and ElevenLabsSwift build on
// iOS too; SwiftGlobalHotkey and AXFocus/AXTextSource use Carbon/AppKit and are
// macOS-only. (The on-device Translation coordinator moved to its own repo,
// AppleTranslationKit, which alone required the macOS 26 floor.)
let package = Package(
    name: "SwiftSpeechSuite",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftLogKit", targets: ["SwiftLogKit"]),
        .library(name: "SwiftSpeechKit", targets: ["SwiftSpeechKit"]),
        .library(name: "SwiftReadingSession", targets: ["SwiftReadingSession"]),
        .library(name: "SwiftGlobalHotkey", targets: ["SwiftGlobalHotkey"]),
        .library(name: "AXFocus", targets: ["AXFocus"]),
        .library(name: "AXTextSource", targets: ["AXTextSource"]),
        .library(name: "ElevenLabsSwift", targets: ["ElevenLabsSwift"]),
    ],
    // swift-docc-plugin is only used by the docs GitHub Pages workflow on `main`.
    // Tagged releases do not carry it, so version-pinned consumers never resolve it.
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(name: "SwiftLogKit"),
        .target(name: "SwiftSpeechKit", dependencies: ["SwiftLogKit"]),
        .target(name: "SwiftReadingSession", dependencies: ["SwiftSpeechKit"]),
        .target(name: "SwiftGlobalHotkey"),
        .target(name: "AXFocus"),
        .target(name: "AXTextSource", dependencies: ["AXFocus"]),
        .target(name: "ElevenLabsSwift"),

        .testTarget(name: "SwiftLogKitTests", dependencies: ["SwiftLogKit"]),
        .testTarget(name: "SwiftSpeechKitTests", dependencies: ["SwiftSpeechKit"]),
        .testTarget(name: "SwiftReadingSessionTests", dependencies: ["SwiftReadingSession"]),
        .testTarget(name: "SwiftGlobalHotkeyTests", dependencies: ["SwiftGlobalHotkey"]),
        .testTarget(name: "AXTextSourceTests", dependencies: ["AXFocus", "AXTextSource"]),
        .testTarget(name: "ElevenLabsSwiftTests", dependencies: ["ElevenLabsSwift"]),
    ]
)
