import Foundation
import notify

/// Universal Control publishes who currently owns the Mac's input through a
/// Darwin notification whose *state* is a bitmask:
///   bit 0 — keyboard is held by the remote device (local keys are discarded)
///   bit 1 — pointer is held by the remote device
/// Readable by any process, no entitlement. Found by watching UniversalControl's
/// own log: "user.uid.<uid>.com.apple.universalcontrol.inputstate: publish filter
/// notification: 0x1".
final class UCState {
    static let shared = UCState()

    private var token: Int32 = 0
    private(set) var available = false
    var onChange: (() -> Void)?

    func start() {
        let name = "user.uid.\(getuid()).com.apple.universalcontrol.inputstate"
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { [weak self] _ in
            self?.onChange?()
        }
        available = status == NOTIFY_STATUS_OK
        Log.info(available ? "watching \(name) (state \(raw))" : "could not register for \(name)")
    }

    var raw: UInt64 {
        guard available else { return 0 }
        var s: UInt64 = 0
        notify_get_state(token, &s)
        return s
    }
    var keyboardHeld: Bool { raw & 1 != 0 }
}
