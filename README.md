# FocusGuard

A menu bar app that keeps you typing when you use a Mac through **Apple Vision Pro's Mac
Virtual Display**.

## The problem

When you look away from the virtual display, visionOS tells Universal Control to take the
Mac's keyboard (`FocusMove keyFocus=true`), and Universal Control starts discarding your local
keystrokes. When you look back, visionOS hands back the pointer but explicitly **not** the
keyboard (`Move Target … keyboard false, pointing true`). The keyboard only returns after a real
hardware mouse-button click. Until then you type into nothing, and the window you were in has
lost focus.

## What FocusGuard does

* Watches Universal Control's own `…universalcontrol.inputstate` notification, so it knows
  exactly when visionOS holds the keyboard — no guessing from app activations.
* While it does, reads your physical keys through `IOHIDManager` (which still sees them below
  Universal Control's filter) and **re-types them into the Mac app you were using**, and brings
  that window back to the front on the first key.
* Re-typing is gated on that notification, so it never overlaps with native typing: if
  visionOS hands the keyboard back, FocusGuard stops in the same instant.
* **Passthrough** (menu, ⌃⌥⌘P, or a key on your keyboard — see below) turns all of it off and
  leaves macOS and visionOS to decide where typing goes.
* The menu bar icon shows who has the keyboard: normal, re-typing, passthrough, or a lock when
  a password field is blocking it.
* Password fields need help from the keyboard itself: with the
  [companion QMK firmware](https://github.com/illixion/qmk_firmware/tree/illixion/keyboards/ducky/one2sf/1967st/ansi/keymaps/illixion)
  it relays them over an encrypted channel (see [Password fields](#password-fields-secure-event-input)).

## Requirements

* macOS 13 or later, Apple silicon or Intel.
* **Accessibility** (to post key events and raise windows) and **Input Monitoring** (to read the
  keyboard). The menu lists both and opens the right Settings pane.
* **Relaunch the app once after granting Input Monitoring** — macOS only applies that grant to
  a fresh process.

## Install

    ./build.sh --install

Builds a universal binary, signs it, copies it to `~/Applications/FocusGuard.app` and starts it.
The first build creates a self-signed certificate in your login keychain (`FocusGuard Menu Bar
(local signing)`). That is deliberate: macOS ties the two permissions to the app's code
signature, and ad-hoc signing changes it on every rebuild so the grants silently stop applying.
The certificate never leaves your machine. Use **Launch at Login** in the menu to keep it running.

Don't run it alongside another keystroke re-injector: two of them would type everything twice.

## Using it

| | |
|---|---|
| Menu bar icon | `keyboard` normal · `keyboard.badge.ellipsis` re-typing · `visionpro` passthrough · lock = a password field is blocking it · ⚠ permissions missing |
| Passthrough | menu item, **⌃⌥⌘P**, or the keyboard's own key if its firmware sends the passthrough report (`0xEF`) |
| Bring the window back when typing | menu toggle (on by default) |
| Keep global shortcuts working while re-typing | menu toggle (on by default) — see below |
| Finder keys | menu toggles: ⌫ → Trash / ⇧⌫ → delete immediately (on), Return opens (off), F2 renames (off) |
| Logs | `log stream --predicate 'subsystem == "com.illixion.focusguard"' --level info` |

## Privacy

FocusGuard handles your keystrokes while it re-types them, so it is strict about them:

* It **never logs which keys were pressed**, under any setting. The log holds state changes
  only (steal started, window restored, relay opened or closed).
* Keys are read, posted straight to the target app, and not stored. There is no network access.
* Read the code: the whole path is `Sources/KeyBridge.swift`, plus `Sources/PanelDriver.swift`
  for file panels (it reads the panel's file names to type-select; the typed prefix stays in
  memory only and is discarded when the next key comes more than a second later).

## Global shortcuts

Re-typed keys are posted straight to the app you were using, which skips the system's hotkey
stage, so another app's global shortcut (Rectangle, Raycast, …) would land in that app as a plain
chord. With the option on, chords with ⌘, ⌃ or ⌥ go through the session event stream instead,
which does reach global shortcuts and is not swallowed by Universal Control — but only while
that app is frontmost, since the session stream delivers to whichever app is.

## Finder keys

Optional Windows Explorer-style keys in Finder, replacing the abandoned PresButan: ⌫/⌦ move the
selection to the Trash, ⇧⌫/⇧⌦ delete it immediately, and optionally Return opens and F2 renames.
They work with any keyboard, whether or not visionOS holds it, and stay out of the way while you
rename a file, type in Finder's search field, or use Spotlight. Code: `Sources/FinderKeys.swift`.

## Open and Save panels

The file list in an Open/Save panel ignores re-typed keys: the panel runs in a separate process,
and the list answers synthetic keystrokes with the error beep. While that list has focus,
FocusGuard performs the keys through Accessibility instead. Typing a name selects it, ↑/↓ move,
→/← expand or collapse, ⌘↑ goes to the enclosing folder, ⌘↓ opens the selection, Return presses
Open/Save and Esc cancels. Other keys are re-typed as usual. Code: `Sources/PanelDriver.swift`.

## Password fields (Secure Event Input)

While a password field, `pinentry`, or Terminal with *Secure Keyboard Entry* is active, macOS
hides keystrokes from every non-privileged reader — including FocusGuard. Without help the
icon shows a lock; click once with a real mouse button (a side button is enough, it has no click
side effect) to take the keyboard back.

### Optional keyboard relay

If your keyboard runs QMK firmware that speaks the FocusGuard protocol, FocusGuard can type into
password fields too: the keyboard relays the keys itself over its vendor HID interface, which
Secure Event Input does not cover. The reference firmware is the
[`illixion` keymap for the Ducky One 2 SF](https://github.com/illixion/qmk_firmware/tree/illixion/keyboards/ducky/one2sf/1967st/ansi/keymaps/illixion) in
[illixion/qmk_firmware](https://github.com/illixion/qmk_firmware); any keyboard that implements the
same packets works. Without it FocusGuard still does everything except password fields.

**Setup** (Ducky One 2 SF; for other boards, port the keymap's `fg/` directory):

1. Install FocusGuard first (`./build.sh --install`), so it can be given access to the key.
2. Clone the fork, check out the `illixion` branch, and from the keymap directory
   (`keyboards/ducky/one2sf/1967st/ansi/keymaps/illixion`) run `tools/fg-provision.sh`. It
   creates a 256-bit key in your login Keychain (`com.illixion.focusguard.keyboard`) that only
   FocusGuard can read without asking.
3. Run `tools/fg-flash.sh`. It reads the key (approve the Keychain prompt), builds the firmware
   in a private temporary directory, asks you to put the keyboard in bootloader mode (unplug,
   hold D+L, plug in), flashes it and deletes every build file.
4. Relaunch FocusGuard and choose *Always Allow* when macOS asks about the Keychain item. The menu
   then shows *Keyboard relay: ready*.

The key exists only in the Keychain and in the keyboard: no file in either repo holds it, so
neither clone gives it away. To replace it, run `tools/fg-provision.sh --rotate`, then
`tools/fg-flash.sh`.

**How it is locked down:**

* FocusGuard opens the relay only while visionOS holds the keyboard **and** a password field is
  active, and closes it the moment either stops. The keyboard also closes it by itself after 3 s
  without an authenticated heartbeat, and after 15 minutes at most.
* While it is open, **the whole keyboard pulses red** (Esc solid red), over every effect and even
  the privacy blackout, and **keys reach only the relay**, not the Mac's normal keyboard input. A
  relay opened by anything else therefore stops your typing instead of silently copying it.
* **Esc closes it**: the Esc still reaches the password prompt (it cancels pinentry), the relay
  ends, and the keyboard refuses a new one for 10 s. FocusGuard keeps it closed for the rest of
  that prompt.
* The start command is authenticated and every key frame is encrypted and authenticated
  (ChaCha20-Poly1305, strictly increasing counters, a fresh random session per start), so another
  process on the Mac cannot open the relay, read the keys off the same HID interface, or inject
  keystrokes into it. The key never crosses USB.

Wire format, threat model and known residual risks (for example: frame *timing* is visible while
the relay is open): [docs/KEYBOARD-PROTOCOL.md](docs/KEYBOARD-PROTOCOL.md). Without a key in the
Keychain the app simply doesn't offer the relay.

`Tests/interop/run.sh` builds the firmware's real C stream/crypto code natively and checks it
byte-for-byte against the Swift side, with a throw-away test key (point `FW_DIR` at the
firmware's `fg/` directory).

## Troubleshooting

* **Nothing is re-typed** — check the menu for missing permissions; after granting Input
  Monitoring, quit and reopen the app.
* **Menu bar freezes for a few seconds at launch** — macOS is asking whether FocusGuard may read
  its Keychain item; choose *Always Allow*.
* **Typing doubles** — another injector is running; quit it.
* **Stale entries in Privacy settings** after an older build — remove them with the − button.

## Limitations

* Media keys, the Fn/Globe key and system-wide shortcuts are not re-typed while the keyboard is
  held by visionOS.
* Without the relay, password fields need the one-click reclaim described above.

## License

MIT
