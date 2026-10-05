import Foundation

/// User-facing switches, stored in the app's own defaults domain.
enum Settings {
    private static let d = UserDefaults.standard

    /// Passthrough = stock behaviour: FocusGuard does nothing and macOS / visionOS
    /// decide where typing goes. Off (default) = FocusGuard re-types whatever
    /// Universal Control steals into the Mac app you were using.
    static var passthrough: Bool {
        get { d.bool(forKey: "passthrough") }
        set { d.set(newValue, forKey: "passthrough") }
    }

    /// Also bring the Mac window you were in back to the front on the first
    /// stolen keystroke (not only type into it).
    static var restoreFocus: Bool {
        get { (d.object(forKey: "restoreFocus") as? Bool) ?? true }
        set { d.set(newValue, forKey: "restoreFocus") }
    }

    /// While re-typing, send ⌘/⌃/⌥ chords through the session event stream instead of
    /// straight to the app, so other apps' global shortcuts (Rectangle, Raycast, …) still fire.
    static var globalShortcuts: Bool {
        get { (d.object(forKey: "globalShortcuts") as? Bool) ?? true }
        set { d.set(newValue, forKey: "globalShortcuts") }
    }

    // Finder keys, Windows Explorer style (what PresButan used to do). Any keyboard, steal or not.

    /// ⌫/⌦ move the selection to the Trash, ⇧⌫/⇧⌦ delete it immediately.
    static var finderDelete: Bool {
        get { (d.object(forKey: "finderDelete") as? Bool) ?? true }
        set { d.set(newValue, forKey: "finderDelete") }
    }

    /// Return opens the selection instead of renaming it.
    static var finderReturnOpens: Bool {
        get { d.bool(forKey: "finderReturnOpens") }
        set { d.set(newValue, forKey: "finderReturnOpens") }
    }

    /// F2 renames (sends Return). Pairs with finderReturnOpens.
    static var finderF2Renames: Bool {
        get { d.bool(forKey: "finderF2Renames") }
        set { d.set(newValue, forKey: "finderF2Renames") }
    }

    static var anyFinderKey: Bool { finderDelete || finderReturnOpens || finderF2Renames }
}
