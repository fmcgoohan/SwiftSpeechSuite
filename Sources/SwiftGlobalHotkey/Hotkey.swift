import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// CGEventTap-based global hotkey for read-aloud commands.
public protocol GlobalHotkeyManaging: AnyObject, Sendable {
    @discardableResult
    func start() -> Bool
    func stop()
}

/// One base chord, N variants distinguished by which extra modifiers are
/// also held at the instant the base chord completes — e.g. plain chord =
/// on-device voice, +Shift = ElevenLabs, +Control = local MLX voice.
/// Generalized from two named callbacks (onToggle/onShiftedToggle) once a
/// third variant was needed.
public struct HotkeyVariant: Sendable {
    public var requiredModifierKeyCodes: Set<Int>
    public var action: @Sendable () -> Void

    public init(requiredModifierKeyCodes: Set<Int>, action: @escaping @Sendable () -> Void) {
        self.requiredModifierKeyCodes = requiredModifierKeyCodes
        self.action = action
    }
}

public final class CGEventTapHotkeyManager: GlobalHotkeyManaging, @unchecked Sendable {
    public struct Chord: Sendable, Equatable {
        public var primaryKeyCode: Int
        public var primaryFlagMask: CGEventFlags
        public var secondaryKeyCode: Int
        public var secondaryFlagMask: CGEventFlags

        /// Left-Option+left-Command base chord for read-aloud commands.
        public static let leftOptionLeftCommand = Chord(
            primaryKeyCode: kVK_Option, primaryFlagMask: .maskAlternate,
            secondaryKeyCode: kVK_Command, secondaryFlagMask: .maskCommand
        )

        public init(primaryKeyCode: Int, primaryFlagMask: CGEventFlags, secondaryKeyCode: Int, secondaryFlagMask: CGEventFlags) {
            self.primaryKeyCode = primaryKeyCode
            self.primaryFlagMask = primaryFlagMask
            self.secondaryKeyCode = secondaryKeyCode
            self.secondaryFlagMask = secondaryFlagMask
        }
    }

    private let chord: Chord
    /// Sorted most-specific-first (more required modifiers wins over
    /// fewer) so e.g. a Control+chord press can't accidentally match the
    /// plain-chord (no extra modifier) variant.
    private let variants: [HotkeyVariant]
    private let onPointerClick: @Sendable (CGPoint, pid_t) -> Void

    // Single-threaded by contract: mutated only from the CGEventTap
    // callback thread / whichever thread called start().
    private nonisolated(unsafe) var tap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var primaryDown = false
    private nonisolated(unsafe) var secondaryDown = false
    private nonisolated(unsafe) var modifierDown: [Int: Bool] = [:]
    private nonisolated(unsafe) var chordArmed = false

    public init(
        chord: Chord = .leftOptionLeftCommand,
        variants: [HotkeyVariant],
        onPointerClick: @escaping @Sendable (CGPoint, pid_t) -> Void = { _, _ in }
    ) {
        self.chord = chord
        self.variants = variants.sorted { $0.requiredModifierKeyCodes.count > $1.requiredModifierKeyCodes.count }
        self.onPointerClick = onPointerClick
        for variant in self.variants {
            for keyCode in variant.requiredModifierKeyCodes {
                modifierDown[keyCode] = false
            }
        }
    }

    /// Returns false if the tap could not be created — the caller (doctor)
    /// should surface this as a missing Accessibility/Input Monitoring
    /// permission, not a silent no-op.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<CGEventTapHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        self.runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        self.tap = nil
        self.runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Self-heal: macOS disables a tap whose callback runs too slow.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown {
            let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            onPointerClick(event.location, pid)
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == chord.primaryKeyCode {
                primaryDown = event.flags.contains(chord.primaryFlagMask)
            } else if keyCode == chord.secondaryKeyCode {
                secondaryDown = event.flags.contains(chord.secondaryFlagMask)
            } else if modifierDown[keyCode] != nil, let flagMask = Self.flagMask(forModifierKeyCode: keyCode) {
                modifierDown[keyCode] = event.flags.contains(flagMask)
            }

            let chordDown = primaryDown && secondaryDown
            if chordDown, !chordArmed {
                chordArmed = true
                // Whichever variant fires is decided once, right here, by
                // which extra modifiers were already down — holding/
                // releasing them afterward (while still holding the base
                // chord) can't double-fire or "upgrade," since
                // `chordArmed` only resets when primary+secondary both
                // release.
                let heldModifiers = Set(modifierDown.filter(\.value).keys)
                let matched = variants.first { heldModifiers.isSuperset(of: $0.requiredModifierKeyCodes) }
                matched?.action()
            } else if !chordDown {
                chordArmed = false
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private static func flagMask(forModifierKeyCode keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Command, kVK_RightCommand: return .maskCommand
        default: return nil
        }
    }
}
