import AppKit
import ApplicationServices

/// Remembers which Mac app you were using, and brings it back to the front when
/// Universal Control has taken over as the frontmost app.
final class FocusTracker {
    static let shared = FocusTracker()

    static let thiefBundleID = "com.apple.universalcontrol"

    private(set) var lastGoodApp: NSRunningApplication?
    private var lastGoodWindow: AXUIElement?

    // Loop protection: if visionOS fights back and we restore too often, back off.
    private var restoreTimes: [Date] = []
    private var suspendedUntil = Date.distantPast

    static func isThief(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier?.lowercased() == thiefBundleID
    }

    var frontIsThief: Bool { Self.isThief(NSWorkspace.shared.frontmostApplication) }

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication { noteGood(front) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if Self.isThief(app) {
                Log.info("Universal Control became frontmost")
            } else {
                self?.noteGood(app)
            }
        }
    }

    private func noteGood(_ app: NSRunningApplication) {
        guard !Self.isThief(app), app.processIdentifier != getpid() else { return }
        lastGoodApp = app
        // Let focus settle, then remember the focused window so the AX fallback
        // can raise that specific one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                self?.lastGoodWindow = self?.focusedWindow(of: app)
            }
        }
    }

    /// The app to type into: the frontmost real app, else the last one we saw.
    func targetPid() -> pid_t? {
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isThief(front),
           front.processIdentifier != getpid() {
            return front.processIdentifier
        }
        if let g = lastGoodApp, !g.isTerminated { return g.processIdentifier }
        return nil
    }

    // MARK: Restore

    /// Re-activate the app Universal Control stole focus from. No-op unless UC is
    /// actually frontmost.
    /// Returns true when it actually started re-activating the app (so callers can wait for it).
    @discardableResult
    func restoreIfStolen() -> Bool {
        guard frontIsThief, let target = lastGoodApp, !target.isTerminated else { return false }
        guard Date() >= suspendedUntil else { return false }
        restoreTimes.append(Date())
        restoreTimes.removeAll { $0 < Date().addingTimeInterval(-10) }
        if restoreTimes.count >= 6 {
            suspendedUntil = Date().addingTimeInterval(15)
            Log.info("6 restores within 10s — visionOS is fighting back; backing off for 15s")
            return false
        }
        Log.info("restoring focus to \(target.localizedName ?? "?")")
        if #available(macOS 14.0, *) { target.activate() } else { target.activate(options: [.activateIgnoringOtherApps]) }

        // Verify; escalate to Accessibility if plain activation was refused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            Log.info("0.3 s after restore the frontmost app is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            guard self.frontIsThief else { return }
            Log.info("plain activate refused — trying AX fallback")
            self.axRestore(target)
        }
        return true
    }

    private func axRestore(_ target: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let appEl = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let win = lastGoodWindow {
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, win)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
    }

    private func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
