import XCTest
@testable import DSPi_Console

/// The MIDI control channel's codec against the firmware's own test vectors
/// (`midi_vectors.json`, copied from DSPi `firmware/tests/` on branch
/// usb-midi-control; the C tests and the Python host tool use the same file),
/// and the UMP SysEx reassembly.
final class MIDIControlCodecTests: XCTestCase {

    private struct Vector {
        let name: String
        let hostToDevice: Bool
        let manufacturer: [UInt8]
        let tag: UInt8
        let frame: [UInt8]
        let sysex: [UInt8]
    }

    private static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "midi_vectors", withExtension: "json"),
                                "midi_vectors.json is not in the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return Vector(name: obj["name"] as! String, hostToDevice: (obj["dir"] as! String) == "h2d",
                          manufacturer: Self.hex(obj["mfr"] as! String), tag: UInt8(obj["tag"] as! Int),
                          frame: Self.hex(obj["frame"] as! String), sysex: Self.hex(obj["sysex"] as! String))
        }
    }

    // MARK: - Firmware vectors

    func testVectorsEncodeAndDecode() throws {
        let all = try vectors()
        XCTAssertGreaterThanOrEqual(all.count, 13)
        for v in all {
            XCTAssertEqual(MIDIControlCodec.encode(frame: v.frame, tag: v.tag, manufacturer: v.manufacturer), v.sysex, v.name)
            guard case .success(let decoded) = MIDIControlCodec.decode(v.sysex, manufacturer: v.manufacturer) else {
                XCTFail("\(v.name) does not decode"); continue
            }
            XCTAssertEqual(decoded.tag, v.tag, v.name)
            XCTAssertEqual(decoded.frame, v.frame, v.name)
        }
    }

    func testVectorFramesRebuildFromTheirFields() throws {
        for v in try vectors() {
            if v.hostToDevice {
                let r = try XCTUnwrap(MIDIControlCodec.parseRequestFrame(v.frame), v.name)
                XCTAssertTrue(r.crcOK, v.name)
                let rebuilt = MIDIControlCodec.requestFrame(type: r.type, request: r.request, value: r.value,
                                                            index: r.index, length: r.length, payload: r.payload)
                XCTAssertEqual(rebuilt, v.frame, v.name)
                if r.type == MIDIControlCodec.typeGet {
                    XCTAssertEqual(MIDIControlCodec.getFrame(request: r.request, value: r.value, index: r.index, length: r.length), v.frame, v.name)
                } else {
                    XCTAssertEqual(MIDIControlCodec.setFrame(request: r.request, value: r.value, index: r.index, payload: r.payload), v.frame, v.name)
                }
            } else {
                let f = try XCTUnwrap(MIDIControlCodec.parseDeviceFrame(v.frame), v.name)
                XCTAssertEqual(MIDIControlCodec.replyFrame(type: f.type, status: f.status, payload: f.payload), v.frame, v.name)
            }
        }
    }

    func testDecodedVectorsHaveTheExpectedMeaning() throws {
        let byName = Dictionary(uniqueKeysWithValues: try vectors().map { ($0.name, $0) })
        let platform = try XCTUnwrap(MIDIControlCodec.parseDeviceFrame(try XCTUnwrap(byName["resp_platform"]).frame))
        XCTAssertEqual(platform.type, MIDIControlCodec.typeGetReply)
        XCTAssertEqual(platform.status, 0)
        XCTAssertEqual(platform.payload, [1, 1, 0x16, 4, 1, 6, 0])

        let unknown = try XCTUnwrap(byName["resp_frame_error_unknown_tag"])
        XCTAssertEqual(unknown.tag, MIDIControlCodec.tagUnknown)
        XCTAssertEqual(MIDIControlCodec.parseDeviceFrame(unknown.frame)?.status, LinkStatus.frameError.rawValue)

        let note = try XCTUnwrap(byName["notify_param_changed"])
        XCTAssertEqual(note.tag, MIDIControlCodec.tagNotify)
        let packet = try XCTUnwrap(MIDIControlCodec.parseDeviceFrame(note.frame))
        XCTAssertEqual(packet.type, MIDIControlCodec.typeNotify)
        XCTAssertEqual(packet.payload.first, 0x02)                  // v2
        XCTAssertEqual(packet.payload[1], 0x02)                     // PARAM_CHANGED
        XCTAssertEqual(packet.payload[8], MIDITransport.paramSourceMIDI)

        let bulk = try XCTUnwrap(byName["set_all_params_6136"])
        XCTAssertEqual(bulk.sysex.count, 7032)                      // the largest message (firmware spec)
        XCTAssertEqual(MIDIControlCodec.parseRequestFrame(bulk.frame)?.payload.count, 6136)
    }

    // MARK: - Primitives

    func testCRCCheckValue() {
        XCTAssertEqual(MIDIControlCodec.crc16(Array("123456789".utf8)), 0x29B1)
    }

    func testPackRoundTrip() {
        for n in Array(0...300) + [6143, 6147] {
            let raw = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ n) }
            let packed = MIDIControlCodec.pack7(raw)
            XCTAssertEqual(packed.count, MIDIControlCodec.packedLength(n))
            XCTAssertTrue(packed.allSatisfy { $0 < 0x80 })
            XCTAssertEqual(MIDIControlCodec.unpack7(packed), raw, "length \(n)")
        }
    }

    func testPackWorkedExample() {
        // 7 bytes with the MSB set on bytes 0 and 6 -> MSB byte 0b1000001.
        XCTAssertEqual(MIDIControlCodec.pack7([0x81, 0x02, 0x03, 0x04, 0x05, 0x06, 0xFF, 0x80]),
                       [0x41, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x7F, 0x01, 0x00])
    }

    func testUnpackRejectsMalformed() {
        XCTAssertNil(MIDIControlCodec.unpack7([0x00, 0x80]))            // data byte >= 0x80
        XCTAssertNil(MIDIControlCodec.unpack7([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x00])) // lone MSB byte
        XCTAssertNil(MIDIControlCodec.unpack7([0x02, 0x01]))            // MSB bit for a missing byte
        XCTAssertEqual(MIDIControlCodec.unpack7([]), [])
    }

    func testDecodeSortsForeignFromBroken() {
        let good = MIDIControlCodec.encode(frame: MIDIControlCodec.replyFrame(type: 0x81, status: 0), tag: 5)
        guard case .success = MIDIControlCodec.decode(good) else { return XCTFail() }
        var otherMaker = good; otherMaker[1] = 0x41                      // Roland
        XCTAssertEqual(errorOf(MIDIControlCodec.decode(otherMaker)), .notOurs)
        var otherProduct = good; otherProduct[2] = 0x45
        XCTAssertEqual(errorOf(MIDIControlCodec.decode(otherProduct)), .notOurs)
        var badVersion = good; badVersion[5] = 0x02
        XCTAssertEqual(errorOf(MIDIControlCodec.decode(badVersion)), .malformed)
        XCTAssertEqual(errorOf(MIDIControlCodec.decode([0xF0, 0x7D, 0x44, 0x53, 0x50, 0x01, 0xF7])), .malformed)
        XCTAssertEqual(errorOf(MIDIControlCodec.decode(Array(good.dropLast()))), .malformed)
        // Universal non-real-time (identity reply etc.) is not ours.
        XCTAssertEqual(errorOf(MIDIControlCodec.decode([0xF0, 0x7E, 0x7F, 0x06, 0x02, 0xF7])), .notOurs)
    }

    private func errorOf(_ r: Result<(tag: UInt8, frame: [UInt8]), MIDIControlCodec.DecodeError>) -> MIDIControlCodec.DecodeError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    func testDeviceFrameChecks() {
        var f = MIDIControlCodec.replyFrame(type: 0x82, status: 0, payload: [1, 2, 3])
        XCTAssertNotNil(MIDIControlCodec.parseDeviceFrame(f))
        f[4] ^= 1
        XCTAssertNil(MIDIControlCodec.parseDeviceFrame(f), "CRC")
        XCTAssertNil(MIDIControlCodec.parseDeviceFrame([0x82, 0, 9, 0, 0, 0]), "length field")
        // A non-OK reply never carries a payload.
        XCTAssertEqual(MIDIControlCodec.replyFrame(type: 0x82, status: 1, payload: [1, 2]).count, 6)
    }

    // MARK: - UMP

    func testUMPWordsForTheGetPlatformVector() throws {
        let sysex = Self.hex("f07d445350010100027f000000000004001030f7")
        let words = MIDIUMPSysEx.words(forSysEx: sysex)
        // 18 data bytes: start, continue, end.
        XCTAssertEqual(words.count, 6)
        XCTAssertEqual(words[0], 0x3016_7D44)
        XCTAssertEqual(words[1], 0x5350_0101)
        XCTAssertEqual(words[2] >> 20, 0x302)
        XCTAssertEqual(words[4] >> 16, 0x3036)
        var a = SysExAssembler()
        XCTAssertEqual(a.feed(words), [sysex])
    }

    func testUMPShortMessagesAreComplete() {
        let words = MIDIUMPSysEx.words(forSysEx: [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7])
        XCTAssertEqual(words, [0x3004_7E7F, 0x0601_0000])
        var a = SysExAssembler()
        XCTAssertEqual(a.feed(words), [[0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]])
        XCTAssertEqual(MIDIUMPSysEx.words(forSysEx: [0xF0, 0xF7]), [0x3000_0000, 0])
    }

    func testReassemblyAcrossArbitrarySplits() {
        let messages = [1, 5, 6, 7, 12, 13, 100, 7034].map { n in
            [MIDIControlCodec.sysexStart] + (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 13) & 0x7F } + [MIDIControlCodec.sysexEnd]
        }
        var stream: [UInt32] = []
        for m in messages {
            stream += MIDIUMPSysEx.words(forSysEx: m)
            // Other traffic between messages: a MIDI 1.0 note on (type 2, one
            // word), a MIDI 2.0 note (type 4, two words), a utility NOOP.
            stream += [0x2090_3C64, 0x4090_3C00, 0xABCD_0000, 0x0000_0000]
        }
        for chunk in [1, 2, 3, 5, 64, stream.count] {
            var a = SysExAssembler()
            var got: [[UInt8]] = []
            var i = 0
            while i < stream.count {
                let n = min(chunk, stream.count - i)
                got += a.feed(stream[i..<(i + n)])
                i += n
            }
            XCTAssertEqual(got, messages, "chunk \(chunk)")
            XCTAssertEqual(a.aborted, 0)
        }
    }

    func testReassemblyDropsBrokenAndForeignGroupMessages() {
        var a = SysExAssembler()
        let first = MIDIUMPSysEx.words(forSysEx: [0xF0] + Array(repeating: 0x11, count: 20) + [0xF7])
        let second = MIDIUMPSysEx.words(forSysEx: [0xF0, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xF7])
        // A start without its end, then a whole message: the first is abandoned.
        XCTAssertEqual(a.feed(first.prefix(4)) + a.feed(second), [[0xF0, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xF7]])
        XCTAssertEqual(a.aborted, 1)
        // Group 1 is someone else's.
        let otherGroup = MIDIUMPSysEx.words(forSysEx: [0xF0, 0x01, 0xF7], group: 1)
        XCTAssertEqual(a.feed(otherGroup), [])
        // A continue with no start is dropped.
        XCTAssertEqual(a.feed(first[2...3]), [])
        // Over the size cap.
        a.maxLength = 10
        XCTAssertEqual(a.feed(first), [])
    }
}
