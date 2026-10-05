import AppKit
import ApplicationServices

/// Finder keys that work like Windows Explorer, replacing the abandoned PresButan:
/// ⌫/⌦ → ⌘⌫ (move to Trash), ⇧⌫/⇧⌦ → ⌘⌥⌫ (delete immediately), and optionally
/// Return → ⌘O (open) and F2 → Return (rename). Each is a setting.
///
/// Two entry points, because keys reach Finder two ways:
///   • normally, a session-level event tap rewrites the key in place (any keyboard);
///   • while visionOS holds the keyboard, KeyBridge re-types keys straight to the app, which
///     never passes that tap, so it asks `handleStolen` first.
/// Either way the replacement chord is posted into the session event stream, which reaches the
/// frontmost app even during a steal (measured 2026-10-05).
final class FinderKeys {
    static let shared = FinderKeys()

    static let tag: Int64 = 0x464B_4559          // "FKEY": our own posts, never remapped again
    private static let finderID = "com.apple.finder"
    private static let axTimeout: Float = 0.05     // the tap is synchronous; never stall typing

    private struct SynthKey { let vk: CGKeyCode; let flags: CGEventFlags }

    private var tap: CFMachPort?
    private var consumed = Set<UInt8>()          // steal path: usages whose key-up must be dropped
    private let source = CGEventSource(stateID: .hidSystemState)

    // MARK: Lifecycle

    /// Install or remove the tap to match the settings. Needs Accessibility.
    func refresh() {
        let want = Settings.anyFinderKey && AXIsProcessTrusted()
        if want && tap == nil { install() }
        else if !want, let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
            tap = nil
            Log.info("Finder keys off")
        }
    }

    private func install() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            FinderKeys.shared.tapped(type, event)
        }, userInfo: nil) else {
            Log.info("Finder keys: event tap could not be created (Accessibility?)")
            return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        Log.info("Finder keys on")
    }

    // MARK: The remap

    /// nil = leave the key alone. Other modifier combinations pass through, so ⌘⌫, ⌥⌫ etc.
    /// keep their real meaning.
    private func remap(vk: CGKeyCode, flags: CGEventFlags) -> [SynthKey]? {
        let mods = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        switch vk {
        case 0x24, 0x4C:                                             // return, keypad enter
            guard Settings.finderReturnOpens, mods.isEmpty else { return nil }
            return [SynthKey(vk: 0x1F, flags: .maskCommand)]        // ⌘O
        case 0x78:                                                   // F2 (only if the key sends F2, not a media key)
            guard Settings.finderF2Renames, mods.isEmpty else { return nil }
            return [SynthKey(vk: 0x24, flags: [])]                  // Return
        case 0x33, 0x75:                                             // delete, forward delete
            guard Settings.finderDelete else { return nil }
            if mods.isEmpty { return [SynthKey(vk: 0x33, flags: .maskCommand)] }                      // Trash
            if mods == .maskShift { return [SynthKey(vk: 0x33, flags: [.maskCommand, .maskAlternate])] }  // delete now
            return nil
        default:
            return nil
        }
    }

    /// Finder is frontmost and really has the keyboard: not renaming or typing in its search
    /// field, and no Spotlight-style panel (which leaves Finder "frontmost") holding focus.
    /// An unreadable focus counts as editing, so a rename is never turned into a delete.
    private func finderFront() -> pid_t? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == Self.finderID else { return nil }
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axTimeout)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let r = role as? String
        if r == nil || r == kAXTextFieldRole || r == kAXTextAreaRole || r == kAXComboBoxRole { return nil }

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, Self.axTimeout)
        var sv: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &sv) == .success,
           let s = sv, CFGetTypeID(s) == AXUIElementGetTypeID() {
            var owner: pid_t = 0
            if AXUIElementGetPid(s as! AXUIElement, &owner) == .success, owner != pid { return nil }
        }
        return pid
    }

    private func post(_ keys: [SynthKey]) {
        for k in keys {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: k.vk, keyDown: down) else { continue }
                e.flags = k.flags          // set, not merged: a held Shift must not ride into ⌘⌥⌫
                e.setIntegerValueField(.eventSourceUserData, value: Self.tag)
                e.post(tap: .cgSessionEventTap)
            }
        }
    }

    // MARK: Entry points

    private func tapped(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        guard type == .keyDown, !KeyBridge.shared.armed else { return Unmanaged.passUnretained(e) }   // a steal is KeyBridge's
        let tag = e.getIntegerValueField(.eventSourceUserData)
        if tag == Self.tag || tag == KeyBridge.injectTag { return Unmanaged.passUnretained(e) }
        let vk = CGKeyCode(e.getIntegerValueField(.keyboardEventKeycode))
        guard let keys = remap(vk: vk, flags: e.flags), finderFront() != nil else { return Unmanaged.passUnretained(e) }
        // A held key must not queue a stack of Trash confirmations.
        if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        post(keys)
        return nil
    }

    /// Steal path: called by KeyBridge for every re-typed key. Returns true when handled here.
    func handleStolen(usage u: UInt8, down isDown: Bool, flags f: CGEventFlags, isRepeat: Bool) -> Bool {
        // A remapped key fires once: its synthetic repeats are swallowed, and it stays ours
        // until the physical release.
        if !isDown { return isRepeat ? consumed.contains(u) : consumed.remove(u) != nil }
        if consumed.contains(u) { return true }
        guard Settings.anyFinderKey, !isRepeat, let vk = Keymap.vk[u],
              let keys = remap(vk: vk, flags: f), finderFront() != nil else { return false }
        consumed.insert(u)
        post(keys)
        return true
    }
}
