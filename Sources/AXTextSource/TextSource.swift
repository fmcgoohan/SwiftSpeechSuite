@preconcurrency import ApplicationServices
import AppKit
import Foundation
import AXFocus

/// Tiered read-target capture: text selection, then the whole focused
/// field, then the clipboard. Dependencies are injected as protocols/closures
/// so the fallback chain can be unit-tested without a real window/focus.
public protocol FocusTargetProviding: Sendable {
    func captureFocusTarget() async -> FocusTarget?
}

public protocol ClipboardReading: Sendable {
    func readString() -> String?
}

public protocol ClickAnchorProviding: Sendable {
    func clickPosition(forPID pid: pid_t) -> CGPoint?
}

public struct CapturedText: Sendable, Equatable {
    public enum Origin: String, Sendable, Equatable {
        case selection
        case clickedWebContent
        case focusedValue
        case clipboard
    }

    public let text: String
    public let origin: Origin
    public let applicationName: String?
    public let title: String?
    public let url: URL?

    public init(
        text: String,
        origin: Origin = .clipboard,
        applicationName: String? = nil,
        title: String? = nil,
        url: URL? = nil
    ) {
        self.text = text
        self.origin = origin
        self.applicationName = applicationName
        self.title = title
        self.url = url
    }

    /// While a reading is active, only a genuinely different explicit
    /// selection replaces it. Click-derived page text must remain a
    /// pause/resume gesture or every whitespace click would restart a page.
    public func replacesActiveReading(text activeText: String?) -> Bool {
        guard origin == .selection else { return false }
        let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = activeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return !selected.isEmpty && selected != active
    }

    /// Web players can move Accessibility focus from page content to a
    /// control. A focused web value still represents a whole-page request;
    /// explicit selections and clipboard captures remain TTS-only.
    public var isPageAudioEligible: Bool {
        guard let scheme = url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return origin == .clickedWebContent || origin == .focusedValue
    }
}

public struct CapturedTextSource: Sendable, Equatable {
    public let applicationName: String?
    public let title: String?
    public let url: URL?

    public init(applicationName: String? = nil, title: String? = nil, url: URL? = nil) {
        self.applicationName = applicationName
        self.title = title
        self.url = url
    }
}

/// Shared between the event-tap callback and text capture. The event tap is
/// not main-actor-bound, so access is protected rather than dispatched.
public final class ClickAnchorStore: ClickAnchorProviding, @unchecked Sendable {
    private struct Anchor {
        let pid: pid_t
        let position: CGPoint
    }

    private let lock = NSLock()
    private var anchor: Anchor?

    public init() {}

    public func record(position: CGPoint, pid: pid_t) {
        lock.lock()
        anchor = Anchor(pid: pid, position: position)
        lock.unlock()
    }

    public func clickPosition(forPID pid: pid_t) -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        guard anchor?.pid == pid else { return nil }
        return anchor?.position
    }
}

public struct SystemFocusProvider: FocusTargetProviding {
    public init() {}
    public func captureFocusTarget() async -> FocusTarget? {
        await FocusCapture.captureFocusTarget()
    }
}

public struct SystemClipboard: ClipboardReading {
    public init() {}
    public func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

public struct TextSource: Sendable {
    /// Terminal apps' kAXValueAttribute is their entire scrollback buffer —
    /// confirmed against a real long-lived terminal session at 413,621
    /// characters. Without a cap, falling back to "the whole focused field"
    /// on a window with no active selection means reading from the very
    /// first line of scrollback, which can be hours old (the reported bug).
    /// Capping to the tail rather than the head is a no-op for anything
    /// shorter than the cap (ordinary documents), and turns the terminal
    /// case into "read the recent output," which is what's actually wanted.
    private static let maxFieldValueCharacters = 4000

    private let focusProvider: FocusTargetProviding
    private let clipboard: ClipboardReading
    private let clickAnchorProvider: (any ClickAnchorProviding)?
    private let selectedTextReader: @Sendable (AXUIElement) -> String?
    private let clickTextReader: @Sendable (pid_t, CGPoint) -> String?
    private let attributeReader: @Sendable (AXUIElement, String) -> String?
    private let rangeReader: @Sendable (AXUIElement, String) -> (location: Int, length: Int)?
    private let frontmostSourceReader: @Sendable () -> CapturedTextSource
    private let sourceReader: @Sendable (FocusTarget) -> CapturedTextSource

    public init(
        focusProvider: FocusTargetProviding = SystemFocusProvider(),
        clipboard: ClipboardReading = SystemClipboard(),
        clickAnchorProvider: (any ClickAnchorProviding)? = nil,
        selectedTextReader: @escaping @Sendable (AXUIElement) -> String? = FocusCapture.selectedText,
        clickTextReader: @escaping @Sendable (pid_t, CGPoint) -> String? = { pid, position in
            FocusCapture.webTextFromClick(pid: pid, position: position)
        },
        attributeReader: @escaping @Sendable (AXUIElement, String) -> String? = FocusCapture.stringAttribute,
        rangeReader: @escaping @Sendable (AXUIElement, String) -> (location: Int, length: Int)? = FocusCapture.rangeAttribute,
        frontmostSourceReader: @escaping @Sendable () -> CapturedTextSource = {
            CapturedTextSource(applicationName: NSWorkspace.shared.frontmostApplication?.localizedName)
        },
        sourceReader: @escaping @Sendable (FocusTarget) -> CapturedTextSource = { target in
            CapturedTextSource(
                applicationName: NSRunningApplication(processIdentifier: target.pid)?.localizedName,
                title: FocusCapture.windowTitle(target.element),
                url: FocusCapture.documentURL(target.element)
            )
        }
    ) {
        self.focusProvider = focusProvider
        self.clipboard = clipboard
        self.clickAnchorProvider = clickAnchorProvider
        self.selectedTextReader = selectedTextReader
        self.clickTextReader = clickTextReader
        self.attributeReader = attributeReader
        self.rangeReader = rangeReader
        self.frontmostSourceReader = frontmostSourceReader
        self.sourceReader = sourceReader
    }

    /// Selection -> web content from the last click -> visible portion of the
    /// focused field -> whole field (tail-capped) -> clipboard.
    public func captureTextToRead() async -> String? {
        await capture()?.text
    }

    public func capture() async -> CapturedText? {
        guard let target = await focusProvider.captureFocusTarget() else {
            let source = frontmostSourceReader()
            return clipboard.readString().map {
                CapturedText(
                    text: $0,
                    origin: .clipboard,
                    applicationName: source.applicationName,
                    title: source.title,
                    url: source.url
                )
            }
        }
        let source = sourceReader(target)
        let result: (text: String, origin: CapturedText.Origin)?
        if let selected = selectedTextReader(target.element), !selected.isEmpty {
            result = (selected, .selection)
        } else if let position = clickAnchorProvider?.clickPosition(forPID: target.pid),
           let clickedText = clickTextReader(target.pid, position),
           !clickedText.isEmpty
        {
            result = (clickedText, .clickedWebContent)
        } else if let value = attributeReader(target.element, kAXValueAttribute as String), !value.isEmpty {
            if let visible = Self.visibleSubstring(of: value, element: target.element, rangeReader: rangeReader) {
                result = (visible, .focusedValue)
            } else {
                result = (Self.trimmedToTail(value), .focusedValue)
            }
        } else {
            result = clipboard.readString().map { ($0, .clipboard) }
        }
        guard let result, !result.text.isEmpty else { return nil }
        return CapturedText(
            text: result.text,
            origin: result.origin,
            applicationName: source.applicationName,
            title: source.title,
            url: source.url
        )
    }

    /// kAXVisibleCharacterRangeAttribute — confirmed working against
    /// Terminal.app: it reports exactly the range of `value` that's
    /// currently on screen (not the whole scrollback buffer), which is
    /// what "only read what's visible" actually needs. Apps that don't
    /// support this attribute (returns nil, or a degenerate zero-length
    /// range) fall through to the coarser tail-cap.
    private static func visibleSubstring(
        of value: String,
        element: AXUIElement,
        rangeReader: @Sendable (AXUIElement, String) -> (location: Int, length: Int)?
    ) -> String? {
        guard let range = rangeReader(element, kAXVisibleCharacterRangeAttribute as String), range.length > 0 else {
            return nil
        }
        let utf16 = Array(value.utf16)
        let start = max(0, min(range.location, utf16.count))
        let end = max(start, min(range.location + range.length, utf16.count))
        guard end > start else { return nil }
        return String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
    }

    private static func trimmedToTail(_ text: String) -> String {
        guard text.count > maxFieldValueCharacters else { return text }
        return String(text.suffix(maxFieldValueCharacters))
    }
}
