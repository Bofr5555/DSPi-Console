//
//  MIDIControlCodec.swift
//  DSPi Console
//
//  Wire format of the DSPi USB MIDI control channel (firmware option
//  DSPI_USB_MIDI; normative text in the firmware's
//  Documentation/Features/usb_midi_control_spec.md, contract C1 of the iOS
//  work packages).  Pure code with no CoreMIDI dependency, so the unit tests
//  run it against the firmware's own test vectors (midi_vectors.json).
//
//  One SysEx message carries exactly one UART control frame, from the type
//  byte through the CRC16, 7-bit packed:
//
//      F0 <mfr> 'D' 'S' 'P' 01 <tag> <packed frame> F7
//
//  mfr    0x7D (development ID, the firmware default) or a 3-byte ID 00 xx yy.
//  tag    1...0x7E chosen by the host and echoed in the reply; 0x00 marks a
//         device notification; 0x7F is an error reply to a message whose tag
//         the device could not read.
//  frame  host to device: type bReq wValue wIndex wLength payload crc
//         device to host: type status len payload crc
//         (little-endian fields, CRC16-CCITT-FALSE over everything before it)
//  packed groups of up to 7 frame bytes become one byte holding their MSBs
//         (bit i = MSB of byte i) followed by their low 7 bits.
//
//  UMP: CoreMIDI's MIDI 1.0 protocol event lists carry SysEx as 64-bit
//  "Data 64" messages (message type 3) of up to 6 bytes each, without the F0
//  and F7.  `MIDIUMPSysEx` converts both ways.
//

import Foundation

enum MIDIControlCodec {
    static let sysexStart: UInt8 = 0xF0
    static let sysexEnd: UInt8 = 0xF7
    static let magic: [UInt8] = [0x44, 0x53, 0x50]          // "DSP"
    static let version: UInt8 = 0x01
    /// The firmware's default manufacturer ID (non-commercial / development).
    static let developmentManufacturer: [UInt8] = [0x7D]

    static let tagNotify: UInt8 = 0x00
    static let tagUnknown: UInt8 = 0x7F

    static let typeSet: UInt8 = 0x01
    static let typeGet: UInt8 = 0x02
    static let typeNotify: UInt8 = 0x40
    static let typeSetReply: UInt8 = 0x81
    static let typeGetReply: UInt8 = 0x82

    // MARK: - Primitives

    /// CRC16-CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no xorout.
    static func crc16<S: Sequence>(_ bytes: S, initial: UInt16 = 0xFFFF) -> UInt16 where S.Element == UInt8 {
        var crc = initial
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func packedLength(_ n: Int) -> Int {
        let r = n % 7
        return (n / 7) * 8 + (r == 0 ? 0 : r + 1)
    }

    static func pack7(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(packedLength(raw.count))
        var i = 0
        while i < raw.count {
            let end = min(i + 7, raw.count)
            var msbs: UInt8 = 0
            for k in i..<end { msbs |= (raw[k] >> 7) << UInt8(k - i) }
            out.append(msbs)
            for k in i..<end { out.append(raw[k] & 0x7F) }
            i = end
        }
        return out
    }

    /// nil when malformed: a byte >= 0x80, a lone trailing MSB byte, or an
    /// MSB bit set for a byte the group does not have.
    static func unpack7<C: Collection>(_ packed: C) -> [UInt8]? where C.Element == UInt8, C.Index == Int {
        var out = [UInt8]()
        out.reserveCapacity(packed.count * 7 / 8)
        var i = packed.startIndex
        while i < packed.endIndex {
            let end = min(i + 8, packed.endIndex)
            let count = end - i - 1
            guard count >= 1 else { return nil }
            let msbs = packed[i]
            guard msbs < 0x80, (Int(msbs) >> count) == 0 else { return nil }
            for k in 0..<count {
                let b = packed[i + 1 + k]
                guard b < 0x80 else { return nil }
                out.append(b | (((msbs >> UInt8(k)) & 1) << 7))
            }
            i = end
        }
        return out
    }

    // MARK: - Frames

    /// Host-to-device frame: type bReq wValue wIndex wLength payload crc.  A
    /// GET carries no payload and states the length it wants; a SET states
    /// its payload length.
    static func requestFrame(type: UInt8, request: UInt8, value: UInt16, index: UInt16,
                             length: UInt16, payload: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [type, request,
                          UInt8(value & 0xFF), UInt8(value >> 8),
                          UInt8(index & 0xFF), UInt8(index >> 8),
                          UInt8(length & 0xFF), UInt8(length >> 8)]
        f += payload
        let crc = crc16(f)
        f.append(UInt8(crc & 0xFF)); f.append(UInt8(crc >> 8))
        return f
    }

    static func getFrame(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> [UInt8] {
        requestFrame(type: typeGet, request: request, value: value, index: index, length: length, payload: [])
    }

    static func setFrame(request: UInt8, value: UInt16, index: UInt16, payload: [UInt8]) -> [UInt8] {
        requestFrame(type: typeSet, request: request, value: value, index: index,
                     length: UInt16(truncatingIfNeeded: payload.count), payload: payload)
    }

    /// Device-to-host frame (used by fakes and tests): type status len
    /// payload crc.  The payload goes only with status OK, as on the device.
    static func replyFrame(type: UInt8, status: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let body = status == 0 ? payload : []
        var f: [UInt8] = [type, status, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]
        f += body
        let crc = crc16(f)
        f.append(UInt8(crc & 0xFF)); f.append(UInt8(crc >> 8))
        return f
    }

    // MARK: - SysEx messages

    static func encode(frame: [UInt8], tag: UInt8, manufacturer: [UInt8] = developmentManufacturer) -> [UInt8] {
        var m = [sysexStart] + manufacturer + magic + [version, tag & 0x7F]
        m += pack7(frame)
        m.append(sysexEnd)
        return m
    }

    enum DecodeError: Error, Equatable {
        /// SysEx for another manufacturer or product: ignore it.
        case notOurs
        /// Ours, but broken (truncated header, wrong version, bad packing).
        case malformed
    }

    /// One complete SysEx message (F0 ... F7) to (tag, frame).
    static func decode(_ message: [UInt8], manufacturer: [UInt8] = developmentManufacturer)
        -> Result<(tag: UInt8, frame: [UInt8]), DecodeError> {
        guard message.count >= 2, message.first == sysexStart, message.last == sysexEnd else {
            return .failure(.malformed)
        }
        let body = message[1..<(message.count - 1)]
        let idEnd = body.startIndex + manufacturer.count
        let magicEnd = idEnd + magic.count
        guard body.count >= manufacturer.count + magic.count,
              Array(body[body.startIndex..<idEnd]) == manufacturer,
              Array(body[idEnd..<magicEnd]) == magic else {
            return .failure(.notOurs)
        }
        guard body.endIndex - magicEnd >= 2, body[magicEnd] == version else { return .failure(.malformed) }
        let tag = body[magicEnd + 1]
        guard let frame = unpack7(body[(magicEnd + 2)...]) else { return .failure(.malformed) }
        return .success((tag, frame))
    }

    /// A parsed device-to-host frame: a reply or a notification.
    struct DeviceFrame: Equatable {
        let type: UInt8
        let status: UInt8
        let payload: [UInt8]
    }

    /// nil when the frame is short, its length field disagrees with its size,
    /// or its CRC is wrong.
    static func parseDeviceFrame(_ frame: [UInt8]) -> DeviceFrame? {
        guard frame.count >= 6 else { return nil }
        let length = Int(frame[2]) | Int(frame[3]) << 8
        guard frame.count == 4 + length + 2 else { return nil }
        let crc = UInt16(frame[frame.count - 2]) | UInt16(frame[frame.count - 1]) << 8
        guard crc16(frame[0..<(frame.count - 2)]) == crc else { return nil }
        return DeviceFrame(type: frame[0], status: frame[1], payload: Array(frame[4..<(4 + length)]))
    }

    /// A parsed host-to-device frame (fakes and tests).
    struct RequestFrame: Equatable {
        let type: UInt8
        let request: UInt8
        let value: UInt16
        let index: UInt16
        let length: UInt16
        let payload: [UInt8]
        let crcOK: Bool
    }

    static func parseRequestFrame(_ frame: [UInt8]) -> RequestFrame? {
        guard frame.count >= 10 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(frame[i]) | UInt16(frame[i + 1]) << 8 }
        let crc = u16(frame.count - 2)
        return RequestFrame(type: frame[0], request: frame[1], value: u16(2), index: u16(4), length: u16(6),
                            payload: Array(frame[8..<(frame.count - 2)]),
                            crcOK: crc16(frame[0..<(frame.count - 2)]) == crc)
    }
}

// MARK: - UMP (MIDI 1.0 protocol event lists)

/// SysEx in Universal MIDI Packets, as CoreMIDI's `MIDIEventList` carries it
/// for `._1_0` ports: "Data 64" messages (type 3), two words each, status
/// complete (0) / start (1) / continue (2) / end (3), up to six data bytes,
/// F0 and F7 implied.
enum MIDIUMPSysEx {
    /// The UMP words for one complete SysEx message (F0 ... F7), group 0.
    static func words(forSysEx message: [UInt8], group: UInt8 = 0) -> [UInt32] {
        var body = message
        if body.first == MIDIControlCodec.sysexStart { body.removeFirst() }
        if body.last == MIDIControlCodec.sysexEnd { body.removeLast() }
        var words: [UInt32] = []
        words.reserveCapacity((body.count / 6 + 1) * 2)
        var i = 0
        repeat {
            let n = min(6, body.count - i)
            let first = i == 0
            let last = i + n >= body.count
            let status: UInt32 = first && last ? 0 : first ? 1 : last ? 3 : 2
            var b = [UInt8](repeating: 0, count: 6)
            for k in 0..<n { b[k] = body[i + k] }
            words.append(0x3000_0000 | UInt32(group & 0x0F) << 24 | status << 20 | UInt32(n) << 16
                         | UInt32(b[0]) << 8 | UInt32(b[1]))
            words.append(UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5]))
            i += n
        } while i < body.count
        return words
    }

    /// Number of 32-bit words in a UMP message, from its type nibble.
    static func messageWordCount(_ firstWord: UInt32) -> Int {
        switch firstWord >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}

/// Rebuilds complete SysEx messages from UMP words that may arrive split
/// across any number of event packets and read callbacks.  Not thread safe:
/// feed it from one thread (CoreMIDI's read callback is serial).
struct SysExAssembler {
    /// Longer messages are dropped (the largest legitimate one is 7032
    /// bytes, a SET 0xA1).
    var maxLength = 16 * 1024
    /// Only this UMP group is read (the DSPi uses cable / group 0).
    var group: UInt8 = 0

    private var buffer: [UInt8]?
    /// Words left over from a message split across two `feed` calls.
    private var carry: [UInt32] = []
    private(set) var aborted = 0

    init() {}

    /// Feed words in arrival order; returns the messages completed by them.
    mutating func feed<C: Collection>(_ words: C) -> [[UInt8]] where C.Element == UInt32 {
        var out: [[UInt8]] = []
        var pending = carry
        pending.append(contentsOf: words)
        carry.removeAll(keepingCapacity: true)
        var i = 0
        while i < pending.count {
            let size = MIDIUMPSysEx.messageWordCount(pending[i])
            guard i + size <= pending.count else {
                carry = Array(pending[i...])
                break
            }
            if pending[i] >> 28 == 0x3, UInt8((pending[i] >> 24) & 0x0F) == group {
                handle(pending[i], pending[i + 1], into: &out)
            }
            i += size
        }
        return out
    }

    private mutating func handle(_ w0: UInt32, _ w1: UInt32, into out: inout [[UInt8]]) {
        let status = (w0 >> 20) & 0x0F
        let n = min(6, Int((w0 >> 16) & 0x0F))
        let all: [UInt8] = [UInt8((w0 >> 8) & 0xFF), UInt8(w0 & 0xFF),
                            UInt8(w1 >> 24), UInt8((w1 >> 16) & 0xFF), UInt8((w1 >> 8) & 0xFF), UInt8(w1 & 0xFF)]
        let bytes = all[0..<n]
        switch status {
        case 0:                                   // complete in one
            if buffer != nil { aborted += 1 }
            buffer = nil
            out.append([MIDIControlCodec.sysexStart] + bytes + [MIDIControlCodec.sysexEnd])
        case 1:                                   // start
            if buffer != nil { aborted += 1 }
            buffer = [MIDIControlCodec.sysexStart] + bytes
        case 2, 3:                                // continue, end
            guard buffer != nil else { aborted += 1; return }
            buffer!.append(contentsOf: bytes)
            if buffer!.count > maxLength {
                aborted += 1
                buffer = nil
                return
            }
            if status == 3 {
                buffer!.append(MIDIControlCodec.sysexEnd)
                out.append(buffer!)
                buffer = nil
            }
        default:
            break
        }
    }

    /// Drop a half-received message (port closed or switched).
    mutating func reset() {
        buffer = nil
        carry.removeAll()
    }
}
