import AppKit

// FocusGuard — menu bar agent that keeps typing on the Mac when visionOS's Mac
// Virtual Display takes the keyboard away. See README.md.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let status = StatusController()
FocusTracker.shared.start()
UCState.shared.start()
FirmwareLink.shared.onFrame = { KeyBridge.shared.firmwareFrame($0) }
FirmwareLink.shared.start()
status.start()
Log.info("FocusGuard started — accessibility \(status.accessibilityOK), input monitoring \(status.inputMonitoringOK)")

app.run()
