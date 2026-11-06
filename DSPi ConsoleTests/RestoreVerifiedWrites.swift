import XCTest
import Combine
@testable import DSPi_Console

/// Restore-verified writes on a real DSPi through any DeviceTransport (USB
/// MIDI, DSPi Link): the sequence the MIDI and Link hardware tests share.
///
/// Only live parameters are written, each one read back and restored:
/// a PEQ band, a channel name, a channel delay, an output mute, crossfeed
/// frequency and feed, a matrix crosspoint, master volume (only below its
/// current value), and an identical-bytes 0xA1 of the image just read.  The
/// harness refuses any other request, so nothing writes flash.  It starts
/// only if the unit matches the reference (bulk_params.bin and config.json
/// from DSPi tools/reset_info/backup_config.py), stops at the first restore
/// that does not read back, and ends by comparing a fresh 0xA0 and the config
/// reads against the reference.
final class RestoreVerifiedWrites {
    let transport: any DeviceTransport
    /// Extra report lines after the bulk writes (the MIDI transport's 0xA1
    /// round trip).
    var bulkStats: (() -> [String])?

    init(transport: any DeviceTransport) {
        self.transport = transport
    }

    /// Observe the transport's notifications into `notes`.
    func observe() -> AnyCancellable {
        transport.addNotificationObserver { [weak self] n in
            guard let self = self else { return }
            self.notesLock.lock(); self.notes.append(n); self.notesLock.unlock()
        }
    }

    /// Load the reference, check the unit's serial, run the writes off the
    /// main thread.  nil on success, else why it stopped.
    func run(referenceDirectory dir: String, timeout: TimeInterval = 300) throws -> String? {
        let bulkRef = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir + "/bulk_params.bin")))
        guard let configRef = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: dir + "/config.json"))) as? [String: Any] else {
            return "config.json is not an object"
        }
        let serial = Self.cstr(get(0x7E, length: 16))
        guard serial != nil, serial == configRef["serial"] as? String else {
            return "a different unit: \(serial ?? "no serial") vs \(configRef["serial"] as? String ?? "?")"
        }
        let numOutputs = configRef["num_outputs"] as? Int ?? 9
        var failure: String? = "timed out"
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            failure = self.runWrites(bulkRef: bulkRef, configRef: configRef, numOutputs: numOutputs)
            done.signal()
        }
        // Notifications land on the main thread: keep it turning.
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return failure
    }

    private static let allowedSets: Set<UInt8> = [0x42, 0x48, 0x62, 0x64, 0x70, 0x76, 0x9B, 0xD2, 0xA1]

    private(set) var report: [String] = []
    private var notes: [LinkNotification] = []
    private let notesLock = NSLock()

    // MARK: - Helpers

    func get(_ request: UInt8, _ value: UInt16 = 0, index: UInt16 = 2, length: UInt16) -> [UInt8]? {
        precondition(MIDITransport.pureReads.contains(request), "not a pure read")
        if case .success(let d) = transport.getControlResult(request: request, value: value, index: index, length: length) {
            return [UInt8](d)
        }
        return nil
    }

    /// One SET, timed to its reply (a GET queued behind it) and to the
    /// PARAM_CHANGED notification it causes.
    @discardableResult
    private func set(_ label: String, _ request: UInt8, index: UInt16 = 0, _ payload: [UInt8],
                     expectNotify: Bool = true) -> (reply: TimeInterval, notify: TimeInterval?) {
        set(label, request, 0, index: index, payload, expectNotify: expectNotify)
    }

    @discardableResult
    private func set(_ label: String, _ request: UInt8, _ value: UInt16, index: UInt16 = 0, _ payload: [UInt8],
                     expectNotify: Bool = true) -> (reply: TimeInterval, notify: TimeInterval?) {
        precondition(Self.allowedSets.contains(request), "SET 0x\(String(request, radix: 16)) is not on the allowed list")
        notesLock.lock(); let before = notes.count; notesLock.unlock()
        let t0 = Date()
        transport.sendControlRequest(request: request, value: value, index: index, data: Data(payload))
        _ = get(REQ_GET_PLATFORM, length: 7)                       // queued behind the SET
        let reply = Date().timeIntervalSince(t0)
        var notify: TimeInterval?
        if expectNotify {
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                notesLock.lock()
                let fresh = notes.dropFirst(before).first { $0.origin == transport.session }
                notesLock.unlock()
                if let n = fresh { notify = n.receivedAt.timeIntervalSince(t0); break }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        report.append(String(format: "%@: SET 0x%02X + GET in %.1f ms, notification %@", label, request, reply * 1000,
                             notify.map { String(format: "after %.1f ms", $0 * 1000) } ?? "none"))
        return (reply, notify)
    }

    private static func f32(_ b: [UInt8]?, at offset: Int = 0) -> Float? {
        guard let b = b, b.count >= offset + 4 else { return nil }
        return b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    private static func bytes(_ f: Float) -> [UInt8] { withUnsafeBytes(of: f) { Array($0) } }

    private static func hex(_ b: [UInt8]?) -> String? { b.map { $0.map { String(format: "%02x", $0) }.joined() } }

    static func cstr(_ b: [UInt8]?) -> String? {
        guard let b = b else { return nil }
        return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The fields backup_config.py writes, read the same way (same requests,
    /// wValues and lengths), over MIDI.
    private func readConfig(numOutputs: Int) -> [String: Any] {
        var names: [String: Any] = [:]
        for s in 0..<10 { names["\(s)"] = Self.cstr(get(0x93, UInt16(s), length: 32)) ?? NSNull() }
        var routes: [String: Any] = [:]
        for i in 0..<8 { for o in 0..<numOutputs {
            if let r = get(0x71, UInt16(i << 8 | o), length: 8) { routes["\(i)->\(o)"] = Self.hex(r) }
        } }
        var channels: [String: Any] = [:]
        for c in 0..<(8 + numOutputs) { channels["\(c)"] = Self.cstr(get(0x9C, UInt16(c), length: 32)) ?? NSNull() }
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        return [
            "presets": [
                "directory_raw": opt(Self.hex(get(0x95, length: 7))),
                "startup_raw": opt(Self.hex(get(0x97, length: 3))),
                "active_slot": opt(get(0x9A, length: 1)?.first.map { Int($0) }),
                "names": names,
            ],
            "master_volume": [
                "live_db": opt(Self.f32(get(0xD3, length: 4)).map { Double($0) }),
                "saved_db": opt(Self.f32(get(0xD7, length: 4)).map { Double($0) }),
                "mode": opt(get(0xD5, length: 1)?.first.map { Int($0) }),
            ],
            "io": [
                "output_config_mode": opt(get(0x99, length: 1)?.first.map { Int($0) }),
                "output_types": (0..<numOutputs).map { opt(Self.hex(get(0xC1, UInt16($0), length: 1))) },
                "output_pins": (0..<numOutputs).map { opt(Self.hex(get(0x7D, UInt16($0), length: 1))) },
                "i2s_bck_pin": opt(Self.hex(get(0xC3, length: 1))),
                "mck_pin": opt(Self.hex(get(0xC7, length: 1))),
                "i2s_rx_pins": (0..<4).map { opt(Self.hex(get(0xF2, UInt16($0), length: 1))) },
                "spdif_rx_pins": (0..<4).map { opt(Self.hex(get(0xE5, UInt16($0), length: 1))) },
                "dac_hw_mute_config": opt(Self.hex(get(0xEB, length: 16))),
                "ctrl_iface_status": opt(Self.hex(get(0xF9, length: 8))),
            ],
            "matrix_routes": routes,
            "channel_names": channels,
        ]
    }

    /// Differences between a reference JSON object and a fresh read, as paths.
    private static func diff(_ a: Any, _ b: Any, path: String = "") -> [String] {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            return Set(x.keys).union(y.keys).sorted().flatMap { k -> [String] in
                guard let xv = x[k], let yv = y[k] else { return ["\(path)/\(k): only on one side"] }
                return diff(xv, yv, path: "\(path)/\(k)")
            }
        case let (x as [Any], y as [Any]):
            guard x.count == y.count else { return ["\(path): length \(x.count) vs \(y.count)"] }
            return zip(x, y).enumerated().flatMap { diff($1.0, $1.1, path: "\(path)[\($0)]") }
        case let (x as NSNumber, y as NSNumber):
            return abs(x.doubleValue - y.doubleValue) < 1e-6 ? [] : ["\(path): \(x) vs \(y)"]
        case (is NSNull, is NSNull):
            return []
        case let (x as String, y as String):
            return x == y ? [] : ["\(path): \(x) vs \(y)"]
        default:
            return ["\(path): \(a) vs \(b)"]
        }
    }

    func checkAgainstReference(_ label: String, bulkRef: [UInt8], configRef: [String: Any], numOutputs: Int) -> Bool {
        let bulk = get(REQ_GET_ALL_PARAMS, length: UInt16(BULK_PARAMS_SIZE))
        var ok = true
        if bulk != bulkRef {
            ok = false
            let differing = zip(bulk ?? [], bulkRef).enumerated().filter { $1.0 != $1.1 }.map { $0.offset }
            report.append("\(label): 0xA0 DIFFERS (\(bulk?.count ?? 0) B, \(differing.count) bytes differ, first offsets \(differing.prefix(16).map { String(format: "0x%04X", $0) }))")
        } else {
            report.append("\(label): 0xA0 byte-identical to bulk_params.bin")
        }
        let fresh = readConfig(numOutputs: numOutputs)
        var diffs: [String] = []
        for key in ["presets", "master_volume", "io", "matrix_routes", "channel_names"] {
            diffs += Self.diff(configRef[key] ?? NSNull(), fresh[key] ?? NSNull(), path: key)
        }
        if diffs.isEmpty {
            report.append("\(label): config.json fields match")
        } else {
            ok = false
            report.append("\(label): config.json DIFFERS:\n  " + diffs.joined(separator: "\n  "))
        }
        return ok
    }

    // MARK: - The test

    /// nil on success, else why it stopped.
    func runWrites(bulkRef: [UInt8], configRef: [String: Any], numOutputs: Int) -> String? {
        guard checkAgainstReference("start", bulkRef: bulkRef, configRef: configRef, numOutputs: numOutputs) else {
            return "the unit does not match the reference before any write; nothing written"
        }

        var writeMismatches: [String] = []
        /// Write, check, then always restore and verify the restore.  A
        /// write that does not read back is noted; a restore that does not
        /// read back stops everything.
        func step(_ what: String, write: () -> Void, check: () -> Bool, restore: () -> Void, verify: () -> Bool) -> String? {
            write()
            if !check() { writeMismatches.append(what); report.append("\(what): write did NOT read back as sent") }
            restore()
            guard verify() else { return "\(what): RESTORE FAILED, stopping" }
            report.append("\(what): restored and verified")
            return nil
        }

        // 1. PEQ band: USB 8 (channel 7), band 9 (an unused input, last band).
        let ch = 7, band = 9
        func bandRaw() -> [[UInt8]?] {
            (0...4).map { p in get(0x43, UInt16(ch << 8 | band << 3 | p), index: 0, length: 4) }
        }
        let origBand = bandRaw()
        guard origBand.allSatisfy({ $0?.count == 4 }), let t = origBand[0]?.first, let bp = origBand[4]?.first,
              let f = Self.f32(origBand[1]), let q = Self.f32(origBand[2]), let g = Self.f32(origBand[3]) else {
            return "PEQ read failed"
        }
        report.append(String(format: "PEQ ch7 b9 was type %d bypass %d %.1f Hz Q %.3f %.2f dB", t, bp, f, q, g))
        func eq(_ type: UInt8, _ bypass: UInt8, _ freq: Float, _ q: Float, _ gain: Float) -> [UInt8] {
            [UInt8(ch), UInt8(band), type, bypass] + Self.bytes(freq) + Self.bytes(q) + Self.bytes(gain)
        }
        if let e = step("PEQ ch7 b9", write: { set("PEQ ch7 b9 -> peaking 1 kHz Q 2 +1.5 dB", 0x42, eq(1, 0, 1000, 2, 1.5)) },
                        check: { let b = bandRaw(); return Self.f32(b[1]) == 1000 && Self.f32(b[2]) == 2 && Self.f32(b[3]) == 1.5 },
                        restore: { set("PEQ restore", 0x42, eq(t, bp, f, q, g)) },
                        verify: { bandRaw().map { $0 } == origBand }) { return e }

        // 2. Channel name: channel 7.
        guard let origName = get(0x9C, 7, length: 32) else { return "name read failed" }
        var name = [UInt8](repeating: 0, count: 32)
        name.replaceSubrange(0..<9, with: Array("MIDI test".utf8))
        if let e = step("channel 7 name", write: { set("channel 7 name -> 'MIDI test'", 0x9B, 7, index: 2, name) },
                        check: { Self.cstr(get(0x9C, 7, length: 32)) == "MIDI test" },
                        restore: { set("channel 7 name restore", 0x9B, 7, index: 2, origName) },
                        verify: { get(0x9C, 7, length: 32) == origName }) { return e }

        // 3. Delay on channel 7.
        guard let origDelay = get(0x49, 7, index: 0, length: 4) else { return "delay read failed" }
        if let e = step("channel 7 delay", write: { set("channel 7 delay -> 3 ms", 0x48, 7, Self.bytes(3)) },
                        check: { let d = Self.f32(get(0x49, 7, index: 0, length: 4)); report.append("delay read back \(String(describing: d))"); return d.map { abs($0 - 3) < 0.05 } ?? false },
                        restore: { set("channel 7 delay restore", 0x48, 7, origDelay) },
                        verify: { get(0x49, 7, index: 0, length: 4) == origDelay }) { return e }

        // 4. Output mute on output 8 (no pin on this unit).
        guard let origMute = get(0x77, 8, length: 1), let m = origMute.first else { return "mute read failed" }
        let flipped: UInt8 = m == 0 ? 1 : 0
        if let e = step("output 8 mute", write: { set("output 8 mute -> \(flipped)", 0x76, 8, index: 2, [flipped]) },
                        check: { get(0x77, 8, length: 1)?.first == flipped },
                        restore: { set("output 8 mute restore", 0x76, 8, index: 2, origMute) },
                        verify: { get(0x77, 8, length: 1) == origMute }) { return e }

        // 5. Crossfeed frequency and feed.
        guard let origFreq = get(0x63, index: 0, length: 4), let origFeed = get(0x65, index: 0, length: 4),
              let fq = Self.f32(origFreq), let fd = Self.f32(origFeed) else { return "crossfeed read failed" }
        let newFreq: Float = fq == 700 ? 650 : 700, newFeed: Float = fd == 4.5 ? 6 : 4.5
        if let e = step("crossfeed freq/feed", write: {
                            set("crossfeed freq \(fq) -> \(newFreq) Hz", 0x62, Self.bytes(newFreq))
                            set("crossfeed feed \(fd) -> \(newFeed) dB", 0x64, Self.bytes(newFeed)) },
                        check: { let a = Self.f32(get(0x63, index: 0, length: 4)), b = Self.f32(get(0x65, index: 0, length: 4))
                                 report.append("crossfeed read back \(String(describing: a)) Hz, \(String(describing: b)) dB")
                                 return a == newFreq && b == newFeed },
                        restore: { set("crossfeed freq restore", 0x62, origFreq); set("crossfeed feed restore", 0x64, origFeed) },
                        verify: { get(0x63, index: 0, length: 4) == origFreq && get(0x65, index: 0, length: 4) == origFeed }) { return e }

        // 6. Matrix crosspoint input 7 -> output 8.
        guard let origRoute = get(0x71, 7 << 8 | 8, length: 9), origRoute.count >= 8 else { return "matrix read failed" }
        report.append("matrix 7->8 was \(Self.hex(origRoute) ?? "")")
        let en: UInt8 = origRoute[2] == 0 ? 1 : 0
        var restoreRoute = Array(origRoute.prefix(9))
        if restoreRoute.count < 9 { restoreRoute += [UInt8](repeating: 0, count: 9 - restoreRoute.count) }
        if let e = step("matrix 7->8", write: { set("matrix 7->8 enable \(en) -6 dB", 0x70, index: 2, [7, 8, en, 0] + Self.bytes(-6) + [0]) },
                        check: { let r = get(0x71, 7 << 8 | 8, length: 9); return r?[2] == en && Self.f32(r, at: 4) == -6 },
                        restore: { set("matrix 7->8 restore", 0x70, index: 2, restoreRoute) },
                        verify: { get(0x71, 7 << 8 | 8, length: 9) == origRoute }) { return e }

        // 7. Master volume: only down.
        guard let origVol = get(0xD3, length: 4), let v = Self.f32(origVol) else { return "volume read failed" }
        let lower = v - 3
        precondition(lower < v)
        if let e = step("master volume", write: { set(String(format: "master volume %.1f -> %.1f dB", v, lower), 0xD2, Self.bytes(lower)) },
                        check: { Self.f32(get(0xD3, length: 4)) == lower },
                        restore: { set("master volume restore", 0xD2, origVol) },
                        verify: { get(0xD3, length: 4) == origVol }) { return e }

        // 8. Identical-bytes bulk SET of a fresh 0xA0 read.
        guard let image = get(REQ_GET_ALL_PARAMS, length: UInt16(BULK_PARAMS_SIZE)), image.count == Int(BULK_PARAMS_SIZE) else {
            return "bulk read failed"
        }
        var bulkTimes: [TimeInterval] = []
        for i in 0..<3 {
            let r = set("0xA1 identical image #\(i + 1)", 0xA1, image, expectNotify: false)
            bulkTimes.append(r.reply)
            guard get(REQ_GET_ALL_PARAMS, length: UInt16(BULK_PARAMS_SIZE)) == image else { return "state changed after identical 0xA1" }
        }
        report.append(contentsOf: bulkStats?() ?? [])
        notesLock.lock()
        let bulkNotes = notes.filter { $0.eventID == 0x03 }.map { "src \($0.packet.count > 4 ? $0.packet[$0.packet.startIndex + 4] : 0) origin \($0.origin)" }
        let total = notes.count
        notesLock.unlock()
        report.append("BULK_INVALIDATED notifications: \(bulkNotes)")
        notesLock.lock()
        let all = notes.map { n -> String in
            let p = [UInt8](n.packet)
            let src = p.count > 8 && (n.eventID == 0x02 || n.eventID == 0x0C) ? Int(p[8])
                : n.eventID == 0x03 && p.count > 4 ? Int(p[4]) : -1
            let off = n.eventID == 0x02 && p.count > 6 ? String(format: " off 0x%04X", Int(p[4]) | Int(p[5]) << 8) : ""
            return String(format: "evt 0x%02X seq %d src %d%@ origin %d", n.eventID, p.count > 3 ? Int(p[3]) : -1, src, off, Int(n.origin))
        }
        notesLock.unlock()
        report.append("all notifications:\n  " + all.joined(separator: "\n  "))
        report.append("notifications received in total: \(total)")

        Thread.sleep(forTimeInterval: 1)
        guard checkAgainstReference("end", bulkRef: bulkRef, configRef: configRef, numOutputs: numOutputs) else {
            return "final state differs from the reference (see report)"
        }
        return writeMismatches.isEmpty ? nil : "writes that did not read back as sent (all restored): \(writeMismatches)"
    }
}
