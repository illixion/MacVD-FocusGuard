import CryptoKit
import Foundation

/// Wire-level crypto for the QMK secure keystroke stream (see the firmware's
/// docs/PROTOCOL.md). ChaCha20-Poly1305 as in RFC 8439, one 256-bit key shared with
/// the keyboard. Nothing here touches the device; it is pure so it can be tested
/// against the firmware's C code.
enum FG {
    static let cmdStreamStart: UInt8 = 0xB8
    static let cmdStreamPing: UInt8 = 0xB9
    static let cmdStreamStop: UInt8 = 0xBA
    static let cmdStatus: UInt8 = 0xB0
    static let evtFrame: UInt8 = 0xEC
    static let evtEnded: UInt8 = 0xED
    static let endCancelled: UInt8 = 5          // FG_END_CANCELLED: Esc pressed on the keyboard
    static let statusCooldown: UInt8 = 6        // FG_ST_COOLDOWN: refused shortly after an Esc cancel
    static let nonceCommand: UInt8 = 0x01
    static let nonceStream: UInt8 = 0x02
    static let reportSize = 32
}

struct FGKeyFrame: Equatable {
    var counter: UInt32
    var pressed: Bool
    var usage: UInt8
    var mods: UInt8
}

struct FGCrypto {
    let key: SymmetricKey

    init(keyBytes: Data) {
        precondition(keyBytes.count == 32, "device key must be 32 bytes")
        key = SymmetricKey(data: keyBytes)
    }

    /// Constant-time comparison of the two keys.
    func sameKey(as other: FGCrypto) -> Bool {
        key.withUnsafeBytes { a in other.key.withUnsafeBytes { b in
            a.count == b.count && zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        } }
    }

    /// 6-byte little-endian counter (48 bit).
    static func counterBytes(_ c: UInt64) -> [UInt8] { (0..<6).map { UInt8(truncatingIfNeeded: c >> (8 * UInt64($0))) } }

    private func commandNonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var n = [UInt8](repeating: 0, count: 12)
        n[0] = FG.nonceCommand
        n.replaceSubrange(4..<10, with: FGCrypto.counterBytes(counter))
        return try! ChaChaPoly.Nonce(data: n)
    }

    /// 16-byte tag authenticating `message` (command byte, counter, payload).
    func commandTag(message: [UInt8], counter: UInt64) -> [UInt8] {
        let box = try! ChaChaPoly.seal(Data(), using: key, nonce: commandNonce(counter: counter),
                                       authenticating: Data(message))
        return Array(box.tag)
    }

    /// Full 32-byte STREAM_START packet.
    func streamStart(counter: UInt64, session: [UInt8]) -> [UInt8] {
        precondition(session.count == 8)
        let msg = [FG.cmdStreamStart] + FGCrypto.counterBytes(counter) + session
        return pad(msg + commandTag(message: msg, counter: counter))
    }

    /// Full 32-byte STREAM_PING packet.
    func streamPing(counter: UInt64) -> [UInt8] {
        let msg = [FG.cmdStreamPing] + FGCrypto.counterBytes(counter)
        return pad(msg + commandTag(message: msg, counter: counter))
    }

    /// Decrypt one device->host key frame, or nil if it does not authenticate.
    func openFrame(_ report: [UInt8], session: [UInt8]) -> FGKeyFrame? {
        guard report.count >= 24, report[0] == FG.evtFrame, session.count == 8 else { return nil }
        let ctrBytes = Array(report[1..<4])
        let nonceBytes = [FG.nonceStream] + session + ctrBytes
        guard let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: Data(report[4..<8]), tag: Data(report[8..<24])),
              let pt = try? ChaChaPoly.open(box, using: key, authenticating: Data(report[0..<4])),
              pt.count == 4 else { return nil }
        let p = [UInt8](pt)
        let ctr = UInt32(ctrBytes[0]) | UInt32(ctrBytes[1]) << 8 | UInt32(ctrBytes[2]) << 16
        return FGKeyFrame(counter: ctr, pressed: p[0] != 0, usage: p[1], mods: p[2])
    }

    private func pad(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: FG.reportSize - b.count) }
}
