import Foundation

// Cross-checks the Swift CryptoKit implementation against the firmware's C code.
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

let keyBytes = Data((0..<32).map { UInt8($0) })      // same test key the C side is built with
let crypto = FGCrypto(keyBytes: keyBytes)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
let inPipe = Pipe(), outPipe = Pipe()
proc.standardInput = inPipe; proc.standardOutput = outPipe
try proc.run()
let reader = outPipe.fileHandleForReading
var buffer = Data()
func readLine() -> String? {
    while true {
        if let i = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<i], as: UTF8.self); buffer.removeSubrange(...i); return line
        }
        let chunk = reader.availableData
        if chunk.isEmpty { return nil }
        buffer.append(chunk)
    }
}
func send(_ s: String) { inPipe.fileHandleForWriting.write((s + "\n").data(using: .utf8)!) }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: Substring) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! } }
func resp() -> (String, [UInt8]) { let l = readLine()!; let p = l.split(separator: " "); return (String(p[0]), unhex(p[1])) }

let session: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

// 1. a correctly authenticated START is accepted
send("cmd " + hex(crypto.streamStart(counter: 1000, session: session)))
var r = resp(); check(r.0 == "resp" && r.1[1] == 0, "START with valid tag accepted (status \(r.1[1]))")

// 2. frames decrypt with the same session and carry the right payload
send("key 11 1 2"); r = resp()
check(r.0 == "frame", "device emitted a frame")
let f0 = crypto.openFrame(r.1, session: session)
check(f0 == FGKeyFrame(counter: 0, pressed: true, usage: 11, mods: 2), "frame 0 decrypts to the key event")
send("key 11 0 0"); r = resp()
let f1 = crypto.openFrame(r.1, session: session)
check(f1 == FGKeyFrame(counter: 1, pressed: false, usage: 11, mods: 0), "frame 1 decrypts, counter advanced")

// 3. tampering, wrong session and wrong key are all rejected
var bad = r.1; bad[5] ^= 0x01
check(crypto.openFrame(bad, session: session) == nil, "flipped ciphertext bit rejected")
check(crypto.openFrame(r.1, session: [9, 9, 9, 9, 9, 9, 9, 9]) == nil, "wrong session rejected")
check(FGCrypto(keyBytes: Data(repeating: 7, count: 32)).openFrame(r.1, session: session) == nil, "wrong key rejected")

// 4. command replay / forgery / reuse of a session id
send("cmd " + hex(crypto.streamStart(counter: 1000, session: [8, 7, 6, 5, 4, 3, 2, 1]))); r = resp()
check(r.1[1] == 2, "reused counter rejected as replay (status \(r.1[1]))")
send("cmd " + hex(crypto.streamStart(counter: 1001, session: session))); r = resp()
check(r.1[1] == 2, "reused session id rejected (status \(r.1[1]))")
var forged = crypto.streamStart(counter: 2000, session: [8, 7, 6, 5, 4, 3, 2, 1]); forged[20] ^= 0xFF
send("cmd " + hex(forged)); r = resp()
check(r.1[1] == 1, "forged tag rejected (status \(r.1[1]))")
send("cmd " + hex(FGCrypto(keyBytes: Data(repeating: 7, count: 32)).streamStart(counter: 3000, session: [3, 3, 3, 3, 3, 3, 3, 3]))); r = resp()
check(r.1[1] == 1, "command signed with another key rejected")
send("cmd " + hex(crypto.streamPing(counter: 1500))); r = resp()
check(r.1[1] == 0, "valid PING accepted")

// 5. dead-man: no ping for > 3 s ends the stream and tells the host
send("tick 2500"); send("tick 1000")
let ended = readLine()!
check(ended.hasPrefix("evt ec") == false && ended.hasPrefix("evt ed01"), "stream ended by timeout, host notified")
send("key 12 1 0")
send("cmd " + hex(crypto.streamPing(counter: 1600))); r = resp()
check(r.1[1] == 5, "PING after timeout reports not-active (status \(r.1[1]))")

// 6. while a stream is open, typed keys are kept from the host; Esc (cancel) ends it and
//    the keyboard refuses new streams for 10 s
func sup(_ k: Int, _ down: Int) -> Bool { send("sup \(k) \(down)"); return readLine() == "sup 1" }
check(!sup(7, 1), "no stream: key goes to the host normally")
send("cmd " + hex(crypto.streamStart(counter: 4000, session: [4, 4, 4, 4, 4, 4, 4, 4]))); r = resp()
check(r.1[1] == 0, "new stream opened")
check(!sup(7, 0), "release of a key held from before the stream still reaches the host")
check(sup(4, 1) && sup(4, 0), "press and release during the stream are kept from the host")
check(sup(5, 1), "key pressed during the stream kept from the host")
send("cancel")
check(readLine()?.hasPrefix("evt ed05") == true, "Esc cancel ends the stream, host told reason 5")
check(sup(5, 0), "its release after the cancel is kept back too (nothing to release)")
send("cmd " + hex(crypto.streamStart(counter: 4001, session: [5, 5, 5, 5, 5, 5, 5, 5]))); r = resp()
check(r.1[1] == 6, "START refused during the cooldown (status \(r.1[1]))")
send("tick 10001")
send("cmd " + hex(crypto.streamStart(counter: 4002, session: [6, 6, 6, 6, 6, 6, 6, 6]))); r = resp()
check(r.1[1] == 0, "START accepted after the cooldown (status \(r.1[1]))")

proc.terminate()
print(failures == 0 ? "\nALL INTEROP CHECKS PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
