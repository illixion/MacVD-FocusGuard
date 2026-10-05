import AppKit
import ApplicationServices

/// Drives the file list of an AppKit Open/Save panel through Accessibility.
///
/// The panel runs out of process (openAndSavePanelService) and is shown inside the app as a
/// remote view. Its list ignores keys posted to the app's pid (it answers with the error beep),
/// and the HID-level route is swallowed by Universal Control during a steal, so no synthetic
/// keystroke reaches it. Accessibility does: the list's selection, its rows' disclosure, the
/// path menu and the panel's buttons are all usable through the bridged AX tree, steal or not.
/// So while that list has focus, the keys a person uses there are performed directly instead.
///
/// Whether a key is ours is decided on the spot; the work itself runs on a serial queue, so a
/// slow step (the path menu, a folder reloading) never stalls key handling and keys stay in order.
final class PanelDriver {
    static let shared = PanelDriver()

    private static let panelIDs: Set<String> = ["open-panel", "save-panel"]
    private static let typeSelectTimeout: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "com.illixion.focusguard.panel")
    private var consumed = Set<UInt8>()          // keys whose key-down we performed; their key-up is dropped too
    private var buffer = ""                      // queue only
    private var lastTyped = Date.distantPast     // queue only

    private enum Action { case move(Int), disclose(Bool), button(String), up, open, type(String) }

    /// Perform the key in the panel if the panel's list has focus. Returns true when handled,
    /// in which case the key must not also be posted.
    func handle(usage u: UInt8, down isDown: Bool, flags f: CGEventFlags, pid: pid_t) -> Bool {
        if !isDown { return consumed.remove(u) != nil }
        let cmd = f.contains(.maskCommand)
        if !f.intersection([.maskControl, .maskAlternate]).isEmpty { return false }

        let action: Action
        switch (u, cmd) {
        case (0x52, true): action = .up                                  // ⌘↑ enclosing folder
        case (0x51, true): action = .open                                // ⌘↓ open selection
        case (_, true): return false
        case (0x52, false): action = .move(-1)
        case (0x51, false): action = .move(1)
        case (0x4F, false): action = .disclose(true)
        case (0x50, false): action = .disclose(false)
        case (0x28, false), (0x58, false): action = .button("OKButton")  // return, keypad enter
        case (0x29, false): action = .button("CancelButton")             // esc
        default:
            guard let ch = character(usage: u, flags: f) else { return false }
            action = .type(ch)
        }
        guard let (list, panel) = focusedPanelList(pid: pid) else { return false }
        consumed.insert(u)
        queue.async { [self] in perform(action, list: list, panel: panel, pid: pid) }
        return true
    }

    private func perform(_ action: Action, list: AXUIElement, panel: AXUIElement, pid: pid_t) {
        switch action {
        case .move(let d): move(list, by: d)
        case .disclose(let open): disclose(list, open)
        case .button(let id): if let b = find(panel, id: id) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
        case .up: goUp(panel, pid: pid)
        case .open: openSelection(list)
        case .type(let ch): typeSelect(list, ch)
        }
    }

    // MARK: Finding the panel

    private func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    /// The focused outline and its panel, if focus is in an Open/Save panel's file list.
    private func focusedPanelList(pid: pid_t) -> (AXUIElement, AXUIElement)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let list = element(attr(app, kAXFocusedUIElementAttribute)),
              (attr(list, kAXRoleAttribute) as? String) == kAXOutlineRole else { return nil }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(list, kAXSelectedRowsAttribute as CFString, &settable)
        guard settable.boolValue else { return nil }
        var cur = list
        for _ in 0..<8 {
            guard let p = element(attr(cur, kAXParentAttribute)) else { return nil }
            cur = p
            if let id = attr(cur, kAXIdentifierAttribute) as? String, Self.panelIDs.contains(id) { return (list, cur) }
        }
        return nil
    }

    /// A control in the panel by its AX identifier. The panel's AXDefaultButton/AXCancelButton
    /// attributes are listed but come back empty through the remote view, so search instead.
    private func find(_ e: AXUIElement, id: String) -> AXUIElement? {
        if (attr(e, kAXIdentifierAttribute) as? String) == id { return e }
        if (attr(e, kAXRoleAttribute) as? String) == kAXOutlineRole { return nil }   // rows are never controls
        for k in children(e) { if let hit = find(k, id: id) { return hit } }
        return nil
    }

    // MARK: Actions

    private func rows(_ list: AXUIElement) -> [AXUIElement] { (attr(list, kAXRowsAttribute) as? [AXUIElement]) ?? [] }

    private func selectedIndex(_ list: AXUIElement, in rows: [AXUIElement]) -> Int? {
        guard let sel = (attr(list, kAXSelectedRowsAttribute) as? [AXUIElement])?.first else { return nil }
        return rows.firstIndex { CFEqual($0, sel) }
    }

    @discardableResult
    private func select(_ list: AXUIElement, _ row: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(list, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success else { return false }
        AXUIElementPerformAction(row, "AXScrollToVisible" as CFString)
        return true
    }

    private func move(_ list: AXUIElement, by delta: Int) {
        let all = rows(list)
        guard !all.isEmpty else { return }
        let target: Int
        if let i = selectedIndex(list, in: all) { target = max(0, min(all.count - 1, i + delta)) }
        else { target = delta > 0 ? 0 : all.count - 1 }
        select(list, all[target])
    }

    private func disclose(_ list: AXUIElement, _ open: Bool) {
        let all = rows(list)
        guard let i = selectedIndex(list, in: all) else { return }
        AXUIElementSetAttributeValue(all[i], kAXDisclosingAttribute as CFString, (open ? kCFBooleanTrue : kCFBooleanFalse)!)
    }

    /// ⌘↓: what a double-click on the name does: enter a folder, or choose a file.
    private func openSelection(_ list: AXUIElement) {
        let all = rows(list)
        guard let i = selectedIndex(list, in: all), let nameCell = children(all[i]).first else { return }
        // Reports "cannot complete" even when it worked: the cell is gone once the folder loads.
        AXUIElementPerformAction(nameCell, "AXOpen" as CFString)
    }

    /// ⌘↑: the path menu lists the current folder (checked) and then its parents, so press the
    /// entry after the checked one; then select the folder we came out of, as Finder does.
    private func goUp(_ panel: AXUIElement, pid: pid_t) {
        guard let popup = find(panel, id: "where popup"),
              AXUIElementPerformAction(popup, kAXShowMenuAction as CFString) == .success else { return }
        var items: [AXUIElement] = []
        for _ in 0..<20 {                                   // the menu fills in a moment after it opens
            if let menu = children(popup).first { items = children(menu) }
            if !items.isEmpty { break }
            usleep(20_000)
        }
        guard let menu = children(popup).first else { return }
        guard let cur = items.firstIndex(where: { attr($0, "AXMenuItemMarkChar") as? String != nil }),
              cur + 1 < items.count,
              let came = attr(items[cur], kAXTitleAttribute) as? String,
              let parentTitle = attr(items[cur + 1], kAXTitleAttribute) as? String, !parentTitle.isEmpty,
              (attr(items[cur + 1], kAXEnabledAttribute) as? Bool) == true else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)   // already at the top
            return
        }
        AXUIElementPerformAction(items[cur + 1], kAXPressAction as CFString)
        for _ in 0..<40 {                                   // wait for the parent's listing, up to ~2 s
            usleep(50_000)
            guard let (list, _) = focusedPanelList(pid: pid) else { continue }
            let all = rows(list)
            if let row = all.first(where: { name($0) == came }) {
                if selectedIndex(list, in: all) == nil { select(list, row) }
                return
            }
        }
    }

    // MARK: Type-select

    /// The character the key produces in the current keyboard layout.
    private func character(usage u: UInt8, flags f: CGEventFlags) -> String? {
        guard let vk = Keymap.vk[u], let e = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true) else { return nil }
        e.flags = f
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        e.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &len, unicodeString: &chars)
        guard len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len)
        guard let scalar = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        return s
    }

    /// The row's file name: the first text in its first cell.
    private func name(_ row: AXUIElement) -> String? {
        var queue = children(row)
        while !queue.isEmpty {
            let e = queue.removeFirst()
            if let v = attr(e, kAXValueAttribute) as? String, !v.isEmpty { return v }
            if let t = attr(e, kAXTitleAttribute) as? String, !t.isEmpty { return t }
            queue.append(contentsOf: children(e))
        }
        return nil
    }

    private func typeSelect(_ list: AXUIElement, _ ch: String) {
        let now = Date()
        if now.timeIntervalSince(lastTyped) > Self.typeSelectTimeout { buffer = "" }
        lastTyped = now
        if buffer.isEmpty && ch == " " { return }          // a lone space is Quick Look, not a name
        buffer += ch

        let all = rows(list)
        let names = all.map { name($0) ?? "" }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        func starts(_ i: Int, _ p: String) -> Bool { names[i].range(of: p, options: opts) != nil }

        // The same letter again steps through the names starting with it, as AppKit lists do.
        if buffer.count > 1, Set(buffer.lowercased()).count == 1, let current = selectedIndex(list, in: all) {
            let letter = String(buffer.prefix(1))
            let order = Array(current + 1 ..< all.count) + Array(0 ... current)
            if let i = order.first(where: { starts($0, letter) }) { select(list, all[i]); return }
        }
        if let i = names.indices.first(where: { starts($0, buffer) }) { select(list, all[i]) }
    }
}
