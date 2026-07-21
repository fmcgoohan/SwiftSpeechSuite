@preconcurrency import ApplicationServices
import AppKit
import Foundation

/// The Accessibility target that had focus when a read-aloud command began.
public struct FocusTarget: @unchecked Sendable, Equatable {
    public let pid: pid_t
    public let element: AXUIElement

    public init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
    }

    public static func == (lhs: FocusTarget, rhs: FocusTarget) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }
}

public enum FocusCapture {
    /// Electron/Chromium apps (confirmed against the Claude desktop app)
    /// return kAXErrorNoValue for kAXFocusedUIElementAttribute until their
    /// AX tree is explicitly activated, and can take a couple of seconds to
    /// start reporting a focused element even after that — retry for a few
    /// seconds rather than failing outright on the first miss.
    public static func captureFocusTarget() async -> FocusTarget? {
        for _ in 0..<10 {
            if let target = currentFocusTarget() { return target }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return currentFocusTarget()
    }

    public static func currentFocusTarget() -> FocusTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        // Idempotent, harmless on apps that don't recognize it — activates
        // full accessibility-tree construction on Electron/Chromium apps,
        // which otherwise never populate kAXFocusedUIElementAttribute at all.
        _ = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return FocusTarget(pid: pid, element: (focused as! AXUIElement))
    }

    /// Reads a string-valued AX attribute (e.g. kAXSelectedTextAttribute,
    /// kAXValueAttribute) off an already-captured element.
    public static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return string(from: value)
    }

    /// Resolve the current selection from fresh range data before trusting
    /// AXSelectedText, which can remain cached after the user moves the
    /// selection. Document selections are often exposed by a parent web area
    /// rather than the focused leaf, so inspect the accessible hierarchy too.
    public static func selectedText(_ element: AXUIElement) -> String? {
        let candidates = selectionCandidates(startingAt: element)
        var candidatesWithCurrentRange: [AXUIElement] = []

        // WebKit and Chromium commonly represent non-editable document
        // selections with text markers instead of an NSString-style range.
        for candidate in candidates {
            switch markerRangeSelection(candidate) {
            case .unavailable:
                break
            case let .current(selected):
                candidatesWithCurrentRange.append(candidate)
                if let selected, !selected.isEmpty { return selected }
            }
        }

        for candidate in candidates {
            switch characterRangeSelection(candidate) {
            case .unavailable:
                break
            case let .current(selected):
                if !candidatesWithCurrentRange.contains(where: { CFEqual($0, candidate) }) {
                    candidatesWithCurrentRange.append(candidate)
                }
                if let selected, !selected.isEmpty { return selected }
            }
        }

        // Keep compatibility with controls that only implement the legacy
        // attribute, but use it last because some web surfaces cache it.
        for candidate in candidates {
            guard !candidatesWithCurrentRange.contains(where: { CFEqual($0, candidate) }) else {
                continue
            }
            if let selected = stringAttribute(candidate, kAXSelectedTextAttribute as String), !selected.isEmpty {
                return selected
            }
        }

        return nil
    }

    /// Reads web-document text beginning at the paragraph beneath a screen
    /// position. Safari/WebKit expose non-editable page content through text
    /// markers, so this does not require selecting or copying the page text.
    public static func webTextFromClick(pid: pid_t, position: CGPoint) -> String? {
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            application,
            Float(position.x),
            Float(position.y),
            &hitElement
        )
        guard hitError == .success, let hitElement else { return nil }

        let ancestors = parentChain(startingAt: hitElement)
        guard let webArea = ancestors.first(where: {
            stringAttribute($0, kAXRoleAttribute as String) == "AXWebArea"
        }) else {
            return nil
        }

        // Prefer the nearest semantic article/main container. Sites without
        // useful landmarks fall back to the web area, still beginning at the
        // clicked content rather than reading browser chrome.
        let contentElement = ancestors.first(where: {
            guard let subrole = stringAttribute($0, kAXSubroleAttribute as String) else {
                return false
            }
            return subrole == "AXDocumentArticle" || subrole == "AXLandmarkMain"
        }) ?? webArea

        guard let contentRange = parameterizedValue(
            webArea,
            "AXTextMarkerRangeForUIElement",
            contentElement
        ),
        CFGetTypeID(contentRange) == AXTextMarkerRangeGetTypeID()
        else {
            return nil
        }

        let contentMarkerRange = contentRange as! AXTextMarkerRange
        let startMarker: AXTextMarker
        if isDirectTextHit(hitElement) {
            var point = position
            guard let pointValue = AXValueCreate(.cgPoint, &point),
                  let pointMarker = parameterizedValue(
                      webArea,
                      "AXTextMarkerForPosition",
                      pointValue
                  )
            else {
                return nil
            }

            let paragraphRange = parameterizedValue(
                webArea,
                "AXParagraphTextMarkerRangeForTextMarker",
                pointMarker
            ) ?? parameterizedValue(
                webArea,
                "AXTextMarkerRangeForUIElement",
                hitElement
            )
            guard let paragraphRange,
                  CFGetTypeID(paragraphRange) == AXTextMarkerRangeGetTypeID()
            else {
                return nil
            }
            startMarker = AXTextMarkerRangeCopyStartMarker(paragraphRange as! AXTextMarkerRange)
        } else {
            // A click in layout whitespace usually resolves to AXGroup or the
            // web area itself. Give that action deterministic semantics:
            // start at the beginning of the article/main content region.
            startMarker = AXTextMarkerRangeCopyStartMarker(contentMarkerRange)
        }

        let contentEnd = AXTextMarkerRangeCopyEndMarker(contentMarkerRange)
        let readRange = AXTextMarkerRangeCreate(nil, startMarker, contentEnd)

        guard let rawText = parameterizedValue(
            webArea,
            "AXStringForTextMarkerRange",
            readRange
        ).flatMap(string(from:)) else {
            return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func isDirectTextHit(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(element, kAXRoleAttribute as String) else {
            return false
        }
        return [
            kAXStaticTextRole as String,
            kAXHeadingRole as String,
            "AXLink",
            "AXListItem",
            "AXCell",
        ].contains(role)
    }

    private enum RangeSelection {
        case unavailable
        case current(String?)
    }

    private static func markerRangeSelection(_ element: AXUIElement) -> RangeSelection {
        guard let markerRange = attributeValue(element, "AXSelectedTextMarkerRange") else {
            return .unavailable
        }

        var textValue: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange,
            &textValue
        )
        guard error == .success else { return .current(nil) }
        return .current(string(from: textValue))
    }

    private static func characterRangeSelection(_ element: AXUIElement) -> RangeSelection {
        var rangeValue: AnyObject?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeError == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return .unavailable
        }

        var cfRange = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &cfRange) else {
            return .unavailable
        }
        guard cfRange.length > 0 else { return .current(nil) }

        var parameterizedText: AnyObject?
        let textError = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &parameterizedText
        )
        if textError == .success,
           let text = string(from: parameterizedText),
           !text.isEmpty
        {
            return .current(text)
        }

        // A number of native controls expose the range and full value but
        // not AXStringForRange. Slice UTF-16 because AX ranges are reported
        // in NSString coordinates.
        if let value = stringAttribute(element, kAXValueAttribute as String),
           let selected = substring(value, in: cfRange),
           !selected.isEmpty
        {
            return .current(selected)
        }

        return .current(nil)
    }

    /// Reads a CFRange-valued AX attribute — kAXVisibleCharacterRangeAttribute
    /// in particular. Confirmed working against Terminal.app: it reports
    /// exactly the on-screen character range within the full scrollback
    /// buffer, which is what "only read what's visible" actually needs
    /// (a fixed tail-length cap is a much cruder approximation).
    public static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> (location: Int, length: Int)? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &cfRange) else { return nil }
        return (location: cfRange.location, length: cfRange.length)
    }

    public static func windowTitle(_ element: AXUIElement) -> String? {
        if let window = elementAttribute(element, kAXWindowAttribute as String),
           let title = stringAttribute(window, kAXTitleAttribute as String),
           !title.isEmpty {
            return title
        }
        return selectionCandidates(startingAt: element).lazy
            .compactMap { stringAttribute($0, kAXTitleAttribute as String) }
            .first { !$0.isEmpty }
    }

    public static func documentURL(_ element: AXUIElement) -> URL? {
        for candidate in selectionCandidates(startingAt: element) {
            guard let value = attributeValue(candidate, "AXURL") else { continue }
            if let url = value as? URL { return url }
            if let url = value as? NSURL { return url as URL }
            if let string = value as? String, let url = URL(string: string) { return url }
        }
        return nil
    }

    private static func substring(_ text: String, in range: CFRange) -> String? {
        let utf16 = Array(text.utf16)
        let start = max(0, min(range.location, utf16.count))
        let end = max(start, min(range.location + range.length, utf16.count))
        guard end > start else { return nil }
        return String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
    }

    private static func selectionCandidates(startingAt element: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []
        var pending = [element]

        while let candidate = pending.first, candidates.count < 16 {
            pending.removeFirst()
            guard !candidates.contains(where: { CFEqual($0, candidate) }) else { continue }
            candidates.append(candidate)

            for attribute in [
                kAXParentAttribute as String,
                kAXWindowAttribute as String,
                kAXTopLevelUIElementAttribute as String,
            ] {
                if let related = elementAttribute(candidate, attribute),
                   !candidates.contains(where: { CFEqual($0, related) }),
                   !pending.contains(where: { CFEqual($0, related) })
                {
                    pending.append(related)
                }
            }
        }

        return candidates
    }

    private static func parentChain(startingAt element: AXUIElement) -> [AXUIElement] {
        var ancestors: [AXUIElement] = []
        var current: AXUIElement? = element

        while let candidate = current, ancestors.count < 64 {
            guard !ancestors.contains(where: { CFEqual($0, candidate) }) else { break }
            ancestors.append(candidate)
            current = elementAttribute(candidate, kAXParentAttribute as String)
        }

        return ancestors
    }

    private static func attributeValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func parameterizedValue(
        _ element: AXUIElement,
        _ attribute: String,
        _ parameter: AnyObject
    ) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            parameter,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private static func string(from value: AnyObject?) -> String? {
        switch value {
        case let text as String:
            return text
        case let text as NSAttributedString:
            return text.string
        default:
            return nil
        }
    }
}
