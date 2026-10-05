import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Re-types the keystrokes Universal Control steals.
///
/// While the Mac Virtual Display's remote device holds the keyboard, Universal
/// Control discards local keys in the HID *event system* — but the raw device
/// values underneath still reach an IOHIDManager (needs Input Monitoring). So we
/// read the physical keys there and, only while UC reports the keyboard held,
/// post them straight to the Mac app you were using with CGEventPostToPid
/// (targeted delivery bypasses UC's session routing). Gating on UC's own
/// `inputstate` means native and injected typing never overlap.
final class KeyBridge {
    static let shared = KeyBridge()

    /// Set by the app: whether the bridge may act (permissions ok, not passthrough).
    var enabled = true { didSet { refresh(); if !enabled { FirmwareLink.shared.releaseStream() } } }
    var onChange: (() -> Void)?
    private(set) var managerOpen = false
    /// True while we are re-typing a steal.
    private(set) var armed = false

    static let injectTag: Int64 = 0x4647_4B42           // "FGKB": marks our own events
    private let hotkeyUsage: UInt8 = 0x13               // P, with ⌃⌥⌘ held: toggle passthrough

    private var manager: IOHIDManager?
    private var down = Set<UInt8>()              // physical keys currently held (all interfaces deduped)
    private var heldMods = Set<UInt8>()
    private var swallowed = Set<UInt8>()
    private var injected = Set<UInt8>()          // keys we posted a keyDown for
    private var arrayState: [ArrayKey: UInt8] = [:]
    private var firstKeyPending = false
    private var capsOn = false
    private var repeatTimer: Timer?
    private var repeatingUsage: UInt8?
    private var streamTimer: Timer?
    private var sessionRouted = Set<UInt8>()     // chord keys sent through the session stream (key-up follows)
    private let sessionSource = CGEventSource(stateID: .hidSystemState)

    // Keys that arrive while the window is still being brought back are held, in order, and
    // delivered once the app is frontmost: an app that is not active yet answers a key with the
    // error beep and drops it (first letter of a type-select in an Open dialog, for one).
    private struct HeldKey { let usage: UInt8; let isDown: Bool; let flags: CGEventFlags }
    private var gateActive = false
    private var gated: [HeldKey] = []
    private var gateTimer: Timer?

    /// Per-steal summary for debugging "why did the app beep". Counts only: it never records
    /// which keys were pressed or when, so it is safe to log.
    private struct StealStats {
        var typed = 0                       // key-downs re-typed (repeats excluded)
        var panelKeys = 0                   // ...performed in an Open/Save panel's list through Accessibility instead
        var shortcuts = 0                   // ...chords sent through the session stream (global shortcuts reachable)
        var frontNotTarget = 0              // ...that arrived while the target app was not frontmost
        var flagSets: [UInt64: Int] = [:]   // modifier flag combinations attached to them
        var firstFront = "?"
        var focus = "not probed"            // what has keyboard focus once the window is back (pid/role only)
    }
    private var stats = StealStats()

    private struct ArrayKey: Hashable { let device: Int; let cookie: UInt32 }

    // MARK: Lifecycle

    /// Open the HID manager. Returns false if Input Monitoring is not granted yet.
    @discardableResult
    func open() -> Bool {
        if managerOpen { return true }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [[String: Any]] = [[kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06]]
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, sender, value in
            guard let ctx = ctx else { return }
            Unmanaged<KeyBridge>.fromOpaque(ctx).takeUnretainedValue().handle(value: value, sender: sender)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))   // not seizing: native path untouched
        guard r == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = m
        managerOpen = true
        Log.info("keyboard reader open")
        onChange?()
        return true
    }

    /// Re-evaluate whether we should be re-typing right now.
    func refresh() {
        let shouldArm = enabled && managerOpen && UCState.shared.keyboardHeld
        if shouldArm && !armed {
            armed = true
            firstKeyPending = true
            stats = StealStats()
            capsOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
            Log.info("keyboard held by visionOS — re-typing")
            // Secure input can start at any moment; check often so the relay opens before you type.
            streamTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateStream() }
            onChange?()
        } else if !shouldArm && armed {
            disarm()
        }
    }

    /// True while some app (a password field, pinentry, Terminal's Secure Keyboard
    /// Entry) has Secure Event Input on. macOS then withholds keyboard values from
    /// every non-privileged reader — including this one — so nothing can be re-typed.
    var secureInputActive: Bool { IsSecureEventInputEnabled() }

    private func releaseEverything() {
        stopRepeat()
        for u in injected.sorted() { post(usage: u, down: false) }   // leave nothing stuck in the app
        injected.removeAll()
    }

    /// Open the keyboard's encrypted relay only while re-typing AND secure input blinds us.
    private func updateStream() {
        let link = FirmwareLink.shared
        if armed && secureInputActive && link.canStream { link.requestStream() } else { link.releaseStream() }
    }

    /// A decrypted key event from the keyboard firmware (only trusted while re-typing).
    func firmwareFrame(_ f: FGKeyFrame) {
        guard armed else { return }
        keyEvent(f.usage, isDown: f.pressed)
    }

    private func disarm() {
        armed = false
        closeGate()
        streamTimer?.invalidate(); streamTimer = nil
        FirmwareLink.shared.releaseStream()
        releaseEverything()
        let flags = stats.flagSets.sorted { $0.key < $1.key }.map { "0x\(String($0.key, radix: 16)):\($0.value)" }.joined(separator: " ")
        Log.info("steal summary: re-typed \(stats.typed) keys (+\(stats.panelKeys) performed in a file panel, \(stats.shortcuts) chords via the session stream), \(stats.frontNotTarget) while the target app was not frontmost, flags {\(flags)}, first key found \(stats.firstFront) frontmost, focus: \(stats.focus)")
        Log.info("keyboard back on the Mac — re-typing stopped")
        onChange?()
    }

    // MARK: HID input

    private func handle(value: IOHIDValue, sender: UnsafeMutableRawPointer?) {
        let el = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(el) == 0x07 else { return }
        let v = IOHIDValueGetIntegerValue(value)

        if IOHIDElementIsArray(el) {
            // Boot-style report: each slot holds the usage currently pressed (0 = none).
            let key = ArrayKey(device: Int(bitPattern: sender), cookie: IOHIDElementGetCookie(el))
            let new = UInt8(truncatingIfNeeded: max(0, min(v, 255)))
            let old = arrayState[key] ?? 0
            guard old != new else { return }
            arrayState[key] = new
            if old >= 4 { keyEvent(old, isDown: false) }
            if new >= 4 { keyEvent(new, isDown: true) }
            return
        }
        let u = IOHIDElementGetUsage(el)
        guard u >= 4, u <= 0xE7 else { return }
        keyEvent(UInt8(u), isDown: v != 0)
    }

    /// One keyboard has several HID interfaces that all report the same key, so
    /// repeated downs/ups for a key already in that state are dropped.
    private func keyEvent(_ u: UInt8, isDown: Bool) {
        if isDown { guard down.insert(u).inserted else { return } }
        else { guard down.remove(u) != nil else { return } }

        if Keymap.isModifier(u) {
            if isDown { heldMods.insert(u) } else { heldMods.remove(u) }
        }
        if isDown, isHotkey(u) {
            swallowed.insert(u)
            Settings.passthrough.toggle()
            Log.info("passthrough \(Settings.passthrough ? "ON" : "off") (hotkey)")
            onChange?()
            return
        }
        if !isDown, swallowed.remove(u) != nil { return }

        refresh()
        if isDown {
            if armed { inject(u) }
        } else if injected.remove(u) != nil {
            if repeatingUsage == u { stopRepeat() }
            post(usage: u, down: false)
        }
    }

    private func isHotkey(_ u: UInt8) -> Bool {
        guard u == hotkeyUsage else { return false }
        func has(_ a: UInt8, _ b: UInt8) -> Bool { heldMods.contains(a) || heldMods.contains(b) }
        return has(0xE0, 0xE4) && has(0xE2, 0xE6) && has(0xE3, 0xE7)
    }

    // MARK: Injection

    private func inject(_ u: UInt8) {
        guard FocusTracker.shared.targetPid() != nil else { return }
        if firstKeyPending {
            firstKeyPending = false
            if Settings.restoreFocus { holdKeysUntilFrontmost() }
        }
        if u == Keymap.capsLock {                // injected events bypass the OS alpha-lock, so track it ourselves
            capsOn.toggle()
            return
        }
        if stats.focus == "not probed" && !gateActive { stats.focus = focusProbe() }
        post(usage: u, down: true)
        injected.insert(u)
        if !Keymap.isModifier(u) && (!secureInputActive || FirmwareLink.shared.streaming) { startRepeat(u) }
    }

    private func heldFlags() -> CGEventFlags {
        var f: CGEventFlags = []
        for m in heldMods { f.insert(Keymap.modFlag[m] ?? []) }
        return f
    }

    private func holdKeysUntilFrontmost() {
        guard FocusTracker.shared.frontIsThief, FocusTracker.shared.restoreIfStolen() else { return }
        gateActive = true
        let started = Date()
        gateTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if !FocusTracker.shared.frontIsThief || Date().timeIntervalSince(started) > 0.8 {
                t.invalidate()
                self.gateTimer = nil
                // Frontmost is not quite key: give the window a moment to take the keyboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.openGate() }
            }
        }
    }

    private func openGate() {
        guard gateActive else { return }
        gateActive = false
        let held = gated
        gated = []
        stats.focus = focusProbe()
        for k in held { send(usage: k.usage, down: k.isDown, flags: k.flags) }
    }

    private func closeGate() {
        gateTimer?.invalidate()
        gateTimer = nil
        gateActive = false
        gated = []
    }

    /// Who owns keyboard focus right now, as Accessibility sees it. Structure only: roles, counts
    /// and capabilities — never titles, values or file names.
    private func focusProbe() -> String {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.3)
        var value: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &value)
        guard r == .success, let el = value, CFGetTypeID(el) == AXUIElementGetTypeID() else { return "AX error \(r.rawValue)" }
        let ax = el as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(ax, &pid)
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func label(_ e: AXUIElement) -> String {
            let role = (attr(e, kAXRoleAttribute) as? String) ?? "?"
            if let sub = attr(e, kAXSubroleAttribute) as? String { return "\(role)(\(sub))" }
            return role
        }
        var chain = [label(ax)]
        var cur = ax
        for _ in 0..<8 {
            guard let p = attr(cur, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            cur = p as! AXUIElement
            chain.append(label(cur))
        }
        let rows = (attr(ax, kAXChildrenAttribute) as? [AXUIElement])?.count ?? -1
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(ax, kAXSelectedRowsAttribute as CFString, &settable)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        return "pid \(pid) (\(name)) \(chain.joined(separator: " < ")); children \(rows); selectedRows settable \(settable.boolValue)"
    }

    private func post(usage u: UInt8, down isDown: Bool) {
        // Snapshot the modifier state now, so held keys go out exactly as they were typed.
        var f = heldFlags()
        if !Keymap.isModifier(u), capsOn && Keymap.isLetter(u) {
            if f.contains(.maskShift) { f.remove(.maskShift) } else { f.insert(.maskShift) }
        }
        if gateActive { gated.append(HeldKey(usage: u, isDown: isDown, flags: f)); return }
        send(usage: u, down: isDown, flags: f)
    }

    private func send(usage u: UInt8, down isDown: Bool, flags f: CGEventFlags) {
        guard let pid = FocusTracker.shared.targetPid() else { return }
        if let vk = Keymap.modVK[u] {
            // Modifiers go as real flagsChanged transitions; a bare flag on a keyDown is not enough.
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: isDown) else { return }
            e.type = .flagsChanged
            e.flags = f
            e.setIntegerValueField(.eventSourceUserData, value: Self.injectTag)
            e.postToPid(pid)
            return
        }
        let isRepeat = repeatingUsage == u
        if PanelDriver.shared.handle(usage: u, down: isDown, flags: f, pid: pid) {
            if isDown && !isRepeat { stats.panelKeys += 1 }
            return
        }
        if FinderKeys.shared.handleStolen(usage: u, down: isDown, flags: f, isRepeat: isRepeat) { return }
        if routeThroughSession(usage: u, down: isDown, flags: f, pid: pid) {
            if isDown && !isRepeat { stats.shortcuts += 1 }
            return
        }
        guard let vk = Keymap.vk[u], let e = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: isDown) else { return }
        e.flags = f
        e.setIntegerValueField(.eventSourceUserData, value: Self.injectTag)
        e.postToPid(pid)
        if isDown && repeatingUsage != u {
            stats.typed += 1
            stats.flagSets[UInt64(f.rawValue), default: 0] += 1
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != pid { stats.frontNotTarget += 1 }
            if stats.typed == 1 { stats.firstFront = front?.localizedName ?? "?" }
        }
    }

    /// Posting to the app's pid skips the system's hotkey stage, so another app's global
    /// shortcut (Rectangle's ⌃⌥F, Raycast, …) would just land in the target as a plain chord.
    /// The session event stream does pass that stage and, unlike the hardware path, is not
    /// swallowed by Universal Control, so chords go there — but only while the target app is
    /// frontmost, because the session stream delivers to whichever app that is.
    private func routeThroughSession(usage u: UInt8, down isDown: Bool, flags f: CGEventFlags, pid: pid_t) -> Bool {
        if !isDown {
            guard sessionRouted.remove(u) != nil else { return false }
        } else {
            guard Settings.globalShortcuts,
                  !f.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            sessionRouted.insert(u)
        }
        guard let vk = Keymap.vk[u], let e = CGEvent(keyboardEventSource: sessionSource, virtualKey: vk, keyDown: isDown) else { return true }
        e.flags = f
        e.setIntegerValueField(.eventSourceUserData, value: Self.injectTag)
        e.post(tap: .cgSessionEventTap)
        return true
    }

    // MARK: Key repeat
    //
    // macOS generates repeat from the held hardware key, which UC's filter removes, so
    // synthesize it with the user's own settings. Each repeat is a complete down+up tap;
    // flagging an event as autorepeat makes the text system validate it against the
    // (cleared) hardware key state and silently drop it.

    private func repeatSettings() -> (initial: Double, interval: Double)? {
        let d = UserDefaults.standard
        let initial = (d.object(forKey: "InitialKeyRepeat") as? Double) ?? 25     // 1/60 s ticks
        let interval = (d.object(forKey: "KeyRepeat") as? Double) ?? 6
        if initial >= 300000 || interval >= 300000 { return nil }                  // repeat disabled
        return (max(initial, 1) / 60.0, max(interval, 1) / 60.0)
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingUsage = nil
    }

    private func startRepeat(_ u: UInt8) {
        stopRepeat()
        guard let (initial, interval) = repeatSettings() else { return }
        repeatingUsage = u
        repeatTimer = Timer.scheduledTimer(withTimeInterval: initial, repeats: false) { [weak self] _ in
            guard let self = self, self.repeatingUsage == u else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self, self.armed, self.repeatingUsage == u else { self?.stopRepeat(); return }
                // Secure Event Input hides key releases from us, so a held key would repeat forever.
                if self.secureInputActive && !FirmwareLink.shared.streaming { self.releaseEverything(); return }
                self.post(usage: u, down: true)
                self.post(usage: u, down: false)
            }
        }
    }
}
