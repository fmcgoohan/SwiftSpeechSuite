import ApplicationServices
import Testing
@testable import AXFocus
@testable import AXTextSource

private struct FakeFocusProvider: FocusTargetProviding {
    let target: FocusTarget?
    func captureFocusTarget() async -> FocusTarget? { target }
}

private struct FakeClipboard: ClipboardReading {
    let text: String?
    func readString() -> String? { text }
}

private func dummyTarget(pid: pid_t = 1) -> FocusTarget {
    // A real AXUIElement is required by the type, but its actual identity
    // doesn't matter here — the attributeReader closure is what controls
    // the returned values in these tests, not the element itself.
    FocusTarget(pid: pid, element: AXUIElementCreateSystemWide())
}

@Test func fallsBackToClipboardWhenNothingIsFocused() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: nil),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, _ in nil }
    )
    let result = await source.captureTextToRead()
    #expect(result == "clipboard text")
}

@Test func clipboardFallbackRetainsFrontmostApplicationMetadata() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: nil),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, _ in nil },
        frontmostSourceReader: {
            CapturedTextSource(applicationName: "Google Chrome")
        }
    )

    let capture = await source.capture()
    #expect(capture == CapturedText(
        text: "clipboard text",
        origin: .clipboard,
        applicationName: "Google Chrome"
    ))
}

@Test func prefersSelectionOverFieldValue() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        selectedTextReader: { _ in "selected text" },
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "selected text" : "whole field value"
        }
    )
    let result = await source.captureTextToRead()
    #expect(result == "selected text")
}

@Test func captureCarriesApplicationTitleAndURLMetadata() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget(pid: 7)),
        clipboard: FakeClipboard(text: nil),
        selectedTextReader: { _ in "selected text" },
        sourceReader: { target in
            #expect(target.pid == 7)
            return CapturedTextSource(
                applicationName: "Safari",
                title: "An Article",
                url: URL(string: "https://example.com/article")
            )
        }
    )

    let capture = await source.capture()
    #expect(capture == CapturedText(
        text: "selected text",
        origin: .selection,
        applicationName: "Safari",
        title: "An Article",
        url: URL(string: "https://example.com/article")
    ))
}

@Test func freshRangeSelectionWinsOverStaleSelectedTextAttribute() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        selectedTextReader: { _ in "new paragraph" },
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "previous paragraph" : "whole field value"
        }
    )
    let result = await source.captureTextToRead()
    #expect(result == "new paragraph")
}

@Test func explicitSelectionWinsOverClickedWebContent() async {
    let clicks = ClickAnchorStore()
    clicks.record(position: CGPoint(x: 100, y: 200), pid: 7)
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget(pid: 7)),
        clipboard: FakeClipboard(text: "clipboard text"),
        clickAnchorProvider: clicks,
        selectedTextReader: { _ in "selected text" },
        clickTextReader: { _, _ in "clicked article" },
        attributeReader: { _, _ in "whole field value" }
    )

    let result = await source.captureTextToRead()
    #expect(result == "selected text")
}

@Test func clickedWebContentWinsOverFocusedFieldWhenNothingIsSelected() async {
    let clicks = ClickAnchorStore()
    clicks.record(position: CGPoint(x: 100, y: 200), pid: 7)
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget(pid: 7)),
        clipboard: FakeClipboard(text: "clipboard text"),
        clickAnchorProvider: clicks,
        selectedTextReader: { _ in nil },
        clickTextReader: { pid, position in
            #expect(pid == 7)
            #expect(position == CGPoint(x: 100, y: 200))
            return "clicked article"
        },
        attributeReader: { _, _ in "whole field value" }
    )

    let result = await source.captureTextToRead()
    #expect(result == "clicked article")
}

@Test func clickFromAnotherApplicationIsIgnored() async {
    let clicks = ClickAnchorStore()
    clicks.record(position: CGPoint(x: 100, y: 200), pid: 99)
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget(pid: 7)),
        clipboard: FakeClipboard(text: "clipboard text"),
        clickAnchorProvider: clicks,
        selectedTextReader: { _ in nil },
        clickTextReader: { _, _ in "wrong application" },
        attributeReader: { _, _ in "whole field value" }
    )

    let result = await source.captureTextToRead()
    #expect(result == "whole field value")
}

@Test func latestClickReplacesThePreviousApplicationAnchor() {
    let clicks = ClickAnchorStore()
    clicks.record(position: CGPoint(x: 10, y: 20), pid: 7)
    clicks.record(position: CGPoint(x: 30, y: 40), pid: 8)

    #expect(clicks.clickPosition(forPID: 7) == nil)
    #expect(clicks.clickPosition(forPID: 8) == CGPoint(x: 30, y: 40))
}

@Test func newExplicitSelectionReplacesAnActiveReading() {
    let selection = CapturedText(text: "New paragraph", origin: .selection)
    #expect(selection.replacesActiveReading(text: "Previous paragraph"))
    #expect(!selection.replacesActiveReading(text: "  New paragraph\n"))
}

@Test func clickedPageContentDoesNotReplaceAnActiveReading() {
    let page = CapturedText(text: "Whole article", origin: .clickedWebContent)
    #expect(!page.replacesActiveReading(text: "Previous paragraph"))
}

@Test func pageAudioEligibilitySurvivesWebPlayerFocusChanges() {
    let url = URL(string: "https://example.com/article")!
    #expect(CapturedText(text: "Article", origin: .clickedWebContent, url: url).isPageAudioEligible)
    #expect(CapturedText(text: "Article", origin: .focusedValue, url: url).isPageAudioEligible)
    #expect(!CapturedText(text: "Paragraph", origin: .selection, url: url).isPageAudioEligible)
    #expect(!CapturedText(text: "Clipboard", origin: .clipboard, url: url).isPageAudioEligible)
    #expect(!CapturedText(text: "Document", origin: .focusedValue).isPageAudioEligible)
}

@Test func fallsBackToFieldValueWhenNoSelection() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "" : "whole field value"
        }
    )
    let result = await source.captureTextToRead()
    #expect(result == "whole field value")
}

@Test func fallsBackToClipboardWhenFocusedElementHasNoText() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, _ in nil }
    )
    let result = await source.captureTextToRead()
    #expect(result == "clipboard text")
}

/// Regression test for the "Terminal reads from the very first line"
/// report: a terminal's whole-buffer kAXValueAttribute can be hundreds of
/// thousands of characters (confirmed against a real session). No
/// selection should mean "read the recent tail," not "read from the
/// beginning of scrollback."
@Test func longFieldValueWithNoSelectionIsTrimmedToTail() async {
    let longBuffer = (1...10_000).map { "line \($0)" }.joined(separator: "\n")
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "" : longBuffer
        }
    )
    let result = await source.captureTextToRead()
    #expect(result != nil)
    #expect(result!.count <= 4000)
    #expect(longBuffer.hasSuffix(result!))
    #expect(!result!.contains("line 1\n")) // the very first line must not be included
}

@Test func shortFieldValueWithNoSelectionIsNotTrimmed() async {
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "" : "a short field value"
        }
    )
    let result = await source.captureTextToRead()
    #expect(result == "a short field value")
}

/// The actual fix for "reads from the very first line": when the app
/// supports kAXVisibleCharacterRangeAttribute (confirmed against real
/// Terminal.app — it reports exactly what's on screen), use that precise
/// range instead of the coarser tail-length cap.
@Test func usesVisibleCharacterRangeWhenAvailable() async {
    let longBuffer = (1...1000).map { "line \($0)" }.joined(separator: "\n")
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "" : longBuffer
        },
        rangeReader: { _, attribute in
            attribute == kAXVisibleCharacterRangeAttribute as String ? (location: 0, length: 13) : nil // "line 1\nline 2"
        }
    )
    let result = await source.captureTextToRead()
    #expect(result == "line 1\nline 2")
}

@Test func fallsBackToTailCapWhenVisibleRangeIsUnavailable() async {
    let longBuffer = (1...10_000).map { "line \($0)" }.joined(separator: "\n")
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "" : longBuffer
        },
        rangeReader: { _, _ in nil }
    )
    let result = await source.captureTextToRead()
    #expect(result != nil)
    #expect(longBuffer.hasSuffix(result!))
}

@Test func fallsBackToTailCapWhenVisibleRangeIsZeroLength() async {
    let longBuffer = (1...10_000).map { "line \($0)" }.joined(separator: "\n")
    let source = TextSource(
        focusProvider: FakeFocusProvider(target: dummyTarget()),
        clipboard: FakeClipboard(text: "clipboard text"),
        attributeReader: { _, attribute in
            attribute == kAXSelectedTextAttribute as String ? "" : longBuffer
        },
        rangeReader: { _, _ in (location: 5, length: 0) }
    )
    let result = await source.captureTextToRead()
    #expect(result != nil)
    #expect(!result!.isEmpty)
    #expect(longBuffer.hasSuffix(result!))
}
