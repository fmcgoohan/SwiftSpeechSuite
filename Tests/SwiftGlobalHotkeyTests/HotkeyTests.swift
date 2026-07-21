import CoreGraphics
import Testing
@testable import SwiftGlobalHotkey

struct HotkeyTests {
    @Test func chordDefaultIsLeftOptionLeftCommand() {
        let chord = CGEventTapHotkeyManager.Chord.leftOptionLeftCommand
        #expect(chord.primaryFlagMask == .maskAlternate)
        #expect(chord.secondaryFlagMask == .maskCommand)
    }

    @Test func managerConstructsWithVariantsAndStopsCleanly() {
        // Construction sorts variants most-specific-first and pre-seeds the
        // modifier table; a manager that never called start() must still stop
        // without touching a nil event tap.
        let plain = HotkeyVariant(requiredModifierKeyCodes: []) {}
        let oneMod = HotkeyVariant(requiredModifierKeyCodes: [59]) {}
        let twoMod = HotkeyVariant(requiredModifierKeyCodes: [59, 62]) {}
        let manager = CGEventTapHotkeyManager(variants: [plain, oneMod, twoMod])
        manager.stop()
    }
}
