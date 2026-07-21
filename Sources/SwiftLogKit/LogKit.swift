import os

/// A reusable pair of `os.Logger`s (a general `pipeline` channel and a
/// `permissions` channel) bound to a caller-supplied subsystem. Construct one
/// at your app's composition root and pass it where logging is needed:
///
/// ```swift
/// let log = LogKit(subsystem: "com.example.myapp")
/// log.pipeline.notice("started")
/// ```
public struct LogKit: Sendable {
    public let pipeline: Logger
    public let permissions: Logger

    public init(subsystem: String) {
        pipeline = Logger(subsystem: subsystem, category: "pipeline")
        permissions = Logger(subsystem: subsystem, category: "permissions")
    }

    /// Convenience factory for an ad-hoc logger under the same subsystem.
    public static func logger(subsystem: String, category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

/// Zero-configuration convenience used by SpeakFlow's own modules and any
/// caller that just wants shared channels without threading a `LogKit` value
/// through every type. The `subsystem` is overridable exactly once at launch
/// (before first use); the channels are computed so the override takes effect.
/// `os.Logger` is a lightweight value, so constructing it per access is cheap.
public enum SFLog {
    /// Override at app launch to brand log output, e.g.
    /// `SFLog.subsystem = "com.speakflowlocal"`. Defaults to a neutral value
    /// so the package carries no app identity of its own.
    public nonisolated(unsafe) static var subsystem = "app.swiftlogkit"

    public static var pipeline: Logger {
        Logger(subsystem: subsystem, category: "pipeline")
    }

    public static var permissions: Logger {
        Logger(subsystem: subsystem, category: "permissions")
    }
}
