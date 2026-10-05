import Foundation
import IOKit.hid
import Security

/// Optional link to a QMK keyboard running the FocusGuard firmware protocol.
///
/// macOS Secure Event Input (password fields, pinentry) hides keystrokes from every
/// reader FocusGuard has, so the keyboard itself relays them — but only under strict
/// conditions: the stream is started with an authenticated command, every frame is
/// encrypted and authenticated, the keyboard shows a red Esc while it is open, and it
/// stops by itself unless this app keeps pinging. FocusGuard opens it only while it is
/// re-typing *and* secure input is on, and closes it the moment either stops being true.
final class FirmwareLink {
    static let shared = FirmwareLink()

    static let keychainService = "com.illixion.focusguard.keyboard"

    enum State: Equatable { case noKey, noDevice, unsupported, ready, starting, streaming }

    var onFrame: ((FGKeyFrame) -> Void)?
    var onChange: (() -> Void)?
    /// The keyboard's own passthrough key (report 0xEF) was pressed.
    var onPassthroughToggle: (() -> Void)?
    /// Whether passthrough is on right now; mirrored to the keyboard's indicator LED.
    var passthroughState: () -> Bool = { false }
    private var ledSent: Bool?

    private(set) var state: State = .noDevice { didSet { if state != oldValue { onChange?() } } }
    var canStream: Bool { state == .ready || state == .starting || state == .streaming }
    var streaming: Bool { state == .streaming }

    private var crypto: FGCrypto?
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: FG.reportSize)

    private var session: [UInt8]?
    private var lastFrameCounter: Int64 = -1
    private var lastCommandCounter: UInt64 = 0
    private var pingTimer: Timer?
    private var retryAfter = Date.distantPast
    private var wantStream = false
    /// You pressed Esc on the keyboard to close the relay. Respect that for the rest of this
    /// password prompt: don't reopen until secure input or the steal ends (releaseStream).
    private(set) var cancelledByUser = false { didSet { if cancelledByUser != oldValue { onChange?() } } }

    // MARK: Setup

    func start() {
        // Keychain reads can block on an access prompt; never do that on the main thread.
        DispatchQueue.global(qos: .utility).async {
            let key = Self.loadKey()
            DispatchQueue.main.async { self.finishStart(key) }
        }
    }

    private func finishStart(_ key: Data?) {
        if let keyData = key {
            crypto = FGCrypto(keyBytes: keyData)
        } else {
            state = .noKey
            Log.info("firmware link: no key in the Keychain (\(Self.keychainService)) — secure-input relay unavailable")
        }

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDDeviceUsagePageKey: 0xFF60, kIOHIDDeviceUsageKey: 0x61]   // QMK raw HID
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<FirmwareLink>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<FirmwareLink>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }

    /// Re-read the key, e.g. after `fg-provision.sh --rotate` replaced it while we were running
    /// (the keyboard then rejects our tags). At most every 30 s: a read can raise a prompt.
    private var lastReload = Date.distantPast
    private func reloadKey(_ why: String) {
        guard Date().timeIntervalSince(lastReload) > 30 else { return }
        lastReload = Date()
        DispatchQueue.global(qos: .utility).async {
            let key = Self.loadKey()
            DispatchQueue.main.async {
                guard let key = key else { return }
                let fresh = FGCrypto(keyBytes: key)
                guard self.crypto?.sameKey(as: fresh) != true else { return }
                self.crypto = fresh
                if self.state == .noKey { self.state = self.device == nil ? .noDevice : .ready }
                self.retryAfter = .distantPast
                Log.info("firmware link: reloaded the key from the Keychain (\(why))")
            }
        }
    }

    /// 32 bytes, hex-encoded in the Keychain by the firmware's tools/fg-provision.sh.
    private static func loadKey() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let hex = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), hex.count == 64 else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return Data(bytes)
    }

    private func attach(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        device = dev
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, FG.reportSize, { ctx, _, _, _, _, report, len in
            let me = Unmanaged<FirmwareLink>.fromOpaque(ctx!).takeUnretainedValue()
            me.received(Array(UnsafeBufferPointer(start: report, count: len)))
        }, Unmanaged.passUnretained(self).toOpaque())
        state = crypto == nil ? .noKey : .ready
        Log.info("firmware link: keyboard attached")
        if crypto == nil { reloadKey("provisioned since launch?") }
        ledSent = nil
        syncPassthroughLED()
        send([FG.cmdStatus])   // learn the keyboard's counter so ours is always ahead
    }

    private func detach(_ dev: IOHIDDevice) {
        guard device === dev else { return }
        device = nil
        teardown()
        state = crypto == nil ? .noKey : .noDevice
        Log.info("firmware link: keyboard removed")
    }

    // MARK: Stream control (idempotent; called from KeyBridge every 100 ms while armed)

    func requestStream() {
        wantStream = true
        guard state == .ready, !cancelledByUser, Date() >= retryAfter, let crypto = crypto else { return }
        var sid = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, sid.count, &sid) == errSecSuccess else { return }
        session = sid
        lastFrameCounter = -1
        state = .starting
        send(crypto.streamStart(counter: nextCounter(), session: sid))
    }

    func releaseStream() {
        wantStream = false
        cancelledByUser = false
        guard state == .starting || state == .streaming else { return }
        send([FG.cmdStreamStop])        // unauthenticated on purpose: stopping only reduces exposure
        teardown()
        state = crypto == nil ? .noKey : (device == nil ? .noDevice : .ready)
        Log.info("firmware link: stream closed")
    }

    private func teardown() {
        pingTimer?.invalidate(); pingTimer = nil
        session = nil
    }

    private func nextCounter() -> UInt64 {
        lastCommandCounter = max(UInt64(Date().timeIntervalSince1970 * 1000), lastCommandCounter + 1)
        return lastCommandCounter
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let crypto = self.crypto, self.state == .streaming else { return }
            self.send(crypto.streamPing(counter: self.nextCounter()))
        }
    }

    // MARK: Passthrough key + indicator (no secret involved)

    /// Light (or clear) the keyboard's passthrough indicator to match the app's mode.
    func syncPassthroughLED() {
        let on = passthroughState()
        guard device != nil, on != ledSent else { return }
        ledSent = on
        send([0xA6, on ? 1 : 0])
    }

    /// Clear the indicator when the app quits so it never claims a mode nobody is tracking.
    func clearPassthroughLED() {
        guard device != nil else { return }
        send([0xA6, 0])
    }

    // MARK: I/O

    private func send(_ bytes: [UInt8]) {
        guard let dev = device else { return }
        var report = bytes + [UInt8](repeating: 0, count: FG.reportSize - bytes.count)
        let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &report, FG.reportSize)
        if r != kIOReturnSuccess { Log.info(String(format: "firmware link: write failed 0x%08X", r)) }
    }

    private func received(_ report: [UInt8]) {
        guard let first = report.first else { return }
        switch first {
        case FG.evtFrame:
            guard state == .streaming, let crypto = crypto, let sid = session,
                  let frame = crypto.openFrame(report, session: sid) else { return }   // forged/garbled: dropped
            guard Int64(frame.counter) > lastFrameCounter else { return }                // replayed/reordered: dropped
            lastFrameCounter = Int64(frame.counter)
            onFrame?(frame)
        case FG.evtEnded:
            guard state == .starting || state == .streaming else { return }
            let reason = report.count > 1 ? report[1] : 0
            Log.info("firmware link: keyboard ended the stream (reason \(reason))")
            teardown()
            state = .ready
            if reason == FG.endCancelled { cancelledByUser = true }
        case FG.cmdStreamStart:
            guard state == .starting, report.count > 1 else { return }
            if report[1] == 0 {
                state = .streaming
                startPinging()
                Log.info("firmware link: secure stream open")
            } else {
                Log.info("firmware link: stream start refused (status \(report[1]))")
                teardown()
                state = .ready
                // Cooldown = Esc closed a stream moments ago; the keyboard refuses for 10 s.
                retryAfter = Date().addingTimeInterval(report[1] == FG.statusCooldown ? 10 : 2)
                if report[1] == 2 { send([FG.cmdStatus]) }   // counter behind the keyboard's: resync
                if report[1] == 1 { reloadKey("keyboard rejected our tag") }   // key rotated since launch?
            }
        case FG.cmdStatus:
            guard report.count >= 12, report[1] == 0 else { return }
            var ctr: UInt64 = 0
            for i in 0..<6 { ctr |= UInt64(report[6 + i]) << (8 * UInt64(i)) }
            lastCommandCounter = max(lastCommandCounter, ctr)
            if report[3] & 0x01 == 0 {
                Log.info("firmware link: this keyboard build has no key provisioned")
                state = .noKey
            }
        case 0xEF:
            onPassthroughToggle?()
        case 0xFF:
            // The QMKD fallback answering an unknown command: firmware predates the FocusGuard protocol.
            if state == .ready || state == .starting {
                Log.info("firmware link: keyboard firmware does not speak the FocusGuard protocol — flash a current build")
                teardown()
                state = .unsupported
            }
        default:
            break   // OpenRGB / layout traffic from other tools
        }
    }
}
