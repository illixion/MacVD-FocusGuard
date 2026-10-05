import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement

/// The menu bar item: shows who has the keyboard and offers the passthrough toggle.
final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var permissionTimer: Timer?

    var accessibilityOK: Bool { AXIsProcessTrusted() }
    var inputMonitoringOK: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    var permissionsOK: Bool { accessibilityOK && inputMonitoringOK }

    func start() {
        menu.delegate = self
        item.menu = menu
        KeyBridge.shared.onChange = { [weak self] in self?.update() }
        FirmwareLink.shared.onChange = { [weak self] in self?.update() }
        FirmwareLink.shared.passthroughState = { Settings.passthrough }
        FirmwareLink.shared.onPassthroughToggle = { [weak self] in
            Settings.passthrough.toggle()
            Log.info("passthrough \(Settings.passthrough ? "ON" : "off") (keyboard key)")
            self?.update()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            FirmwareLink.shared.clearPassthroughLED()
        }
        UCState.shared.onChange = { [weak self] in KeyBridge.shared.refresh(); self?.update() }

        if !accessibilityOK {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if !inputMonitoringOK { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

        // Permissions are granted in System Settings while we run; keep checking until they are.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        if permissionsOK, !KeyBridge.shared.managerOpen { KeyBridge.shared.open() }
        if KeyBridge.shared.armed { KeyBridge.shared.refresh() }
        FinderKeys.shared.refresh()
        update()
    }

    // MARK: State

    private enum Mode { case needsPermissions, passthrough, retyping, idle }
    private var mode: Mode {
        if !permissionsOK || !KeyBridge.shared.managerOpen { return .needsPermissions }
        if Settings.passthrough { return .passthrough }
        return KeyBridge.shared.armed ? .retyping : .idle
    }

    func update() {
        KeyBridge.shared.enabled = !Settings.passthrough && permissionsOK
        FirmwareLink.shared.syncPassthroughLED()
        let (symbol, text): (String, String) = {
            switch mode {
            case .needsPermissions: return ("exclamationmark.triangle", "FocusGuard needs permissions")
            case .passthrough:      return ("visionpro", "Passthrough — stock behaviour")
            case .retyping:
                if KeyBridge.shared.secureInputActive {
                    if FirmwareLink.shared.streaming {
                        return ("keyboard.badge.ellipsis", "Secure input — re-typing through the keyboard's encrypted relay")
                    }
                    return ("lock.trianglebadge.exclamationmark", "Secure input is on (password field) — keys can't be re-typed")
                }
                return ("keyboard.badge.ellipsis", "Keyboard held by visionOS — re-typing")
            case .idle:             return ("keyboard", "Keyboard on this Mac")
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: text)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = text
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let status = NSMenuItem(title: item.button?.toolTip ?? "FocusGuard", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pass = NSMenuItem(title: "Passthrough (stock behaviour)", action: #selector(togglePassthrough), keyEquivalent: "p")
        pass.keyEquivalentModifierMask = [.control, .option, .command]
        pass.state = Settings.passthrough ? .on : .off
        pass.target = self
        menu.addItem(pass)

        let restore = NSMenuItem(title: "Bring the window back when typing", action: #selector(toggleRestore), keyEquivalent: "")
        restore.state = Settings.restoreFocus ? .on : .off
        restore.isEnabled = !Settings.passthrough
        restore.target = self
        menu.addItem(restore)

        let shortcuts = NSMenuItem(title: "Keep global shortcuts working while re-typing", action: #selector(toggleShortcuts), keyEquivalent: "")
        shortcuts.state = Settings.globalShortcuts ? .on : .off
        shortcuts.isEnabled = !Settings.passthrough
        shortcuts.target = self
        menu.addItem(shortcuts)

        menu.addItem(.separator())
        let finderHeader = NSMenuItem(title: "Finder keys", action: nil, keyEquivalent: "")
        finderHeader.isEnabled = false
        menu.addItem(finderHeader)
        for (title, on, action) in [("⌫ moves to Trash, ⇧⌫ deletes immediately", Settings.finderDelete, #selector(toggleFinderDelete)),
                                    ("Return opens", Settings.finderReturnOpens, #selector(toggleFinderReturn)),
                                    ("F2 renames", Settings.finderF2Renames, #selector(toggleFinderF2))] {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
            row.state = on ? .on : .off
            row.indentationLevel = 1
            row.target = self
            menu.addItem(row)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        for (ok, name, pane) in [(accessibilityOK, "Accessibility", "Privacy_Accessibility"),
                                 (inputMonitoringOK, "Input Monitoring", "Privacy_ListenEvent")] {
            let row = NSMenuItem(title: ok ? "\(name): granted" : "\(name): grant in System Settings…",
                                 action: ok ? nil : #selector(openPane(_:)), keyEquivalent: "")
            row.representedObject = pane
            row.target = self
            menu.addItem(row)
        }
        let fwText: String = {
            switch FirmwareLink.shared.state {
            case .noKey:     return "Keyboard relay: no key (see README)"
            case .noDevice:  return "Keyboard relay: compatible keyboard not found"
            case .unsupported: return "Keyboard relay: firmware too old — reflash"
            case .ready:     return FirmwareLink.shared.cancelledByUser
                ? "Keyboard relay: closed with Esc (stays closed for this password prompt)"
                : "Keyboard relay: ready (opens only for password fields)"
            case .starting:  return "Keyboard relay: starting…"
            case .streaming: return "Keyboard relay: ACTIVE (keyboard pulses red; Esc closes it)"
            }
        }()
        let fw = NSMenuItem(title: fwText, action: nil, keyEquivalent: "")
        fw.isEnabled = false
        menu.addItem(fw)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FocusGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func togglePassthrough() {
        Settings.passthrough.toggle()
        Log.info("passthrough \(Settings.passthrough ? "ON" : "off") (menu)")
        KeyBridge.shared.enabled = !Settings.passthrough && permissionsOK
        update()
    }

    @objc private func toggleRestore() { Settings.restoreFocus.toggle() }
    @objc private func toggleShortcuts() { Settings.globalShortcuts.toggle() }
    @objc private func toggleFinderDelete() { Settings.finderDelete.toggle(); FinderKeys.shared.refresh() }
    @objc private func toggleFinderReturn() { Settings.finderReturnOpens.toggle(); FinderKeys.shared.refresh() }
    @objc private func toggleFinderF2() { Settings.finderF2Renames.toggle(); FinderKeys.shared.refresh() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.info("launch at login failed: \(error)")
        }
    }

    @objc private func openPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
