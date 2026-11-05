import Foundation
import XCTest
@testable import DSPi_Console

/// A DSPi on the far side of a MIDI port, speaking the control protocol
/// (MIDIControlCodec): it reassembles the host's SysEx from UMP words,
/// answers each request through `respond`, and can be told to misbehave.
/// The firmware's behaviour it copies is midi_control.c / tools/midi_ctrl/
/// fake_device.py: ignore other manufacturers, FRAME_ERROR with tag 0x7F,
/// BUSY, payload only with status OK.
final class FakeMIDIDevice {
    typealias Request = MIDIControlCodec.RequestFrame

    var manufacturer = MIDIControlCodec.developmentManufacturer
    /// (status, payload) for a request, or nil for no reply at all.
    var respond: (Request) -> (status: UInt8, payload: [UInt8])?

    /// Where the device's UMP words go (set by the port).
    var emit: (([UInt32]) -> Void)?

    private let lock = NSLock()
    private var assembler = SysExAssembler()
    private var _requests: [(tag: UInt8, frame: Request)] = []

    // Misbehaviour, each consumed one request at a time.
    var busyReplies = 0
    var droppedReplies = 0
    /// Delay before the next reply (it may arrive after the host gave up).
    var delayNextReply: TimeInterval = 0
    /// Send a reply with the previous request's tag before the real one.
    var staleReplyFirst = false
    /// Answer the next request FRAME_ERROR with tag 0x7F.
    var unknownTagError = false

    var requests: [(tag: UInt8, frame: Request)] { lock.lock(); defer { lock.unlock() }; return _requests }

    init(respond: @escaping (Request) -> (status: UInt8, payload: [UInt8])? = FakeMIDIDevice.simpleModel()) {
        self.respond = respond
    }

    func receive(_ words: [UInt32]) {
        lock.lock(); let messages = assembler.feed(words); lock.unlock()
        for m in messages { handle(m) }
    }

    private func handle(_ message: [UInt8]) {
        guard case .success(let (tag, raw)) = MIDIControlCodec.decode(message, manufacturer: manufacturer),
              let request = MIDIControlCodec.parseRequestFrame(raw), request.crcOK else { return }
        lock.lock()
        _requests.append((tag, request))
        var status: UInt8? = nil
        var drop = false
        var delay: TimeInterval = 0
        var stale = false
        if unknownTagError { unknownTagError = false; status = 0x07 }
        else if busyReplies > 0 { busyReplies -= 1; status = 0x01 }
        if droppedReplies > 0 { droppedReplies -= 1; drop = true }
        if delayNextReply > 0 { delay = delayNextReply; delayNextReply = 0 }
        if staleReplyFirst { staleReplyFirst = false; stale = true }
        lock.unlock()
        if drop { return }

        let replyType = request.type == MIDIControlCodec.typeGet ? MIDIControlCodec.typeGetReply : MIDIControlCodec.typeSetReply
        let replyTag = status == 0x07 ? MIDIControlCodec.tagUnknown : tag
        let answer: (status: UInt8, payload: [UInt8])
        if let s = status {
            answer = (s, [])
        } else if let a = respond(request) {
            answer = a
        } else {
            return
        }
        var out: [UInt32] = []
        if stale {
            out += MIDIUMPSysEx.words(forSysEx: MIDIControlCodec.encode(
                frame: MIDIControlCodec.replyFrame(type: replyType, status: 0, payload: [0xEE]),
                tag: tag == 1 ? 0x7E : tag - 1, manufacturer: manufacturer))
        }
        out += MIDIUMPSysEx.words(forSysEx: MIDIControlCodec.encode(
            frame: MIDIControlCodec.replyFrame(type: replyType, status: answer.status, payload: answer.payload),
            tag: replyTag, manufacturer: manufacturer))
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.emit?(out) }
        } else {
            emit?(out)
        }
    }

    /// A tag-0 notification frame carrying a v2 packet.
    func notify(_ packet: [UInt8]) {
        emit?(MIDIUMPSysEx.words(forSysEx: MIDIControlCodec.encode(
            frame: MIDIControlCodec.replyFrame(type: MIDIControlCodec.typeNotify, status: 0, payload: packet),
            tag: MIDIControlCodec.tagNotify, manufacturer: manufacturer)))
    }

    /// Raw SysEx (another product, garbage) straight to the host.
    func sendRaw(_ sysex: [UInt8]) {
        emit?(MIDIUMPSysEx.words(forSysEx: sysex))
    }

    static let platform: [UInt8] = [1, 1, 0x16, 4, 1, 6, 0]
    static let bulkImage: [UInt8] = (0..<6136).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }

    /// v2 PARAM_CHANGED: ver, evt, flags, seq, offset, size, source, 0, 0, 0, value.
    static func paramChanged(seq: UInt8, source: UInt8, value: Float = -20) -> [UInt8] {
        var p: [UInt8] = [0x02, 0x02, 0, seq, 0xD4, 0x0A, 4, 0, source, 0, 0, 0]
        withUnsafeBytes(of: value) { p += $0 }
        return p
    }

    /// Platform, a bulk image, master volume, bulk SET; ERROR (the
    /// firmware's answer to a request it refuses) for anything else.
    static func simpleModel() -> (Request) -> (status: UInt8, payload: [UInt8])? {
        var volume: [UInt8] = [0, 0, 0xA0, 0xC1]
        return { r in
            switch (r.type, r.request) {
            case (MIDIControlCodec.typeGet, 0x7F): return (0, platform)
            case (MIDIControlCodec.typeGet, 0xA0): return (0, bulkImage)
            case (MIDIControlCodec.typeGet, 0xD3): return (0, volume)
            case (MIDIControlCodec.typeSet, 0xD2):
                guard r.payload.count == 4 else { return (0x02, []) }
                volume = r.payload
                return (0, [])
            case (MIDIControlCodec.typeSet, 0xA1):
                return r.payload.count == 6136 ? (0, []) : (0x02, [])
            default: return (0x02, [])
            }
        }
    }

    /// Answers through a FakeTransport (the A2 demo device), so the whole
    /// console request set runs over the MIDI codec.  Its notifications are
    /// forwarded as tag-0 frames.
    static func backed(by fake: FakeTransport) -> FakeMIDIDevice {
        let device = FakeMIDIDevice { r in
            if r.type == MIDIControlCodec.typeGet {
                switch fake.getControlResult(request: r.request, value: r.value, index: r.index, length: r.length) {
                case .success(let data): return (0, [UInt8](data))
                case .failure(let s): return (s.rawValue < 8 ? s.rawValue : 0x02, [])
                }
            }
            fake.sendControlRequest(request: r.request, value: r.value, index: r.index, data: Data(r.payload))
            return (0, [])
        }
        device.forwarding = fake.addNotificationObserver { [weak device] note in
            device?.notify([UInt8](note.packet))
        }
        return device
    }

    var forwarding: AnyObject?
}

/// A MIDIControlPort with one fake DSPi behind it.  Replies come back on a
/// background queue, cut into random pieces (a UMP message may even be split
/// across two callbacks), so the transport's reassembly is exercised.
final class FakeMIDIControlPort: MIDIControlPort {
    static let endpoint = MIDIControlEndpoint(serial: "FAKEMIDI00000001", locationID: 0x0570_0000,
                                              name: "Weeb Labs DSPi DSPi Control", sourceID: 101, destinationID: 102)

    let device: FakeMIDIDevice
    var onEndpointsChanged: (() -> Void)?
    var onReceive: (([UInt32]) -> Void)?
    var unavailableReason: String?
    private let lock = NSLock()
    private var _endpoints: [MIDIControlEndpoint]
    private var opened: MIDIControlEndpoint?
    private(set) var openCount = 0
    private let rx = DispatchQueue(label: "FakeMIDIControlPort.rx")
    private var rng = SystemRandomNumberGenerator()

    var endpoints: [MIDIControlEndpoint] { lock.lock(); defer { lock.unlock() }; return _endpoints }
    var openEndpoint: MIDIControlEndpoint? { lock.lock(); defer { lock.unlock() }; return opened }

    init(device: FakeMIDIDevice = FakeMIDIDevice(), endpoints: [MIDIControlEndpoint] = [FakeMIDIControlPort.endpoint]) {
        self.device = device
        self._endpoints = endpoints
        device.emit = { [weak self] words in self?.deliver(words) }
    }

    /// Hot-plug: change the list and tell the transport, as CoreMIDI would.
    func setEndpoints(_ endpoints: [MIDIControlEndpoint]) {
        lock.lock(); _endpoints = endpoints; lock.unlock()
        DispatchQueue.main.async { self.onEndpointsChanged?() }
    }

    func open(_ endpoint: MIDIControlEndpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _endpoints.contains(endpoint) else { return false }
        opened = endpoint
        openCount += 1
        return true
    }

    func close() {
        lock.lock(); opened = nil; lock.unlock()
    }

    func send(_ words: [UInt32]) -> Bool {
        guard openEndpoint != nil else { return false }
        device.receive(words)
        return true
    }

    private func deliver(_ words: [UInt32]) {
        rx.async { [weak self] in
            guard let self = self, self.openEndpoint != nil else { return }
            var i = 0
            while i < words.count {
                let n = min(words.count - i, Int.random(in: 1...64, using: &self.rng))
                self.onReceive?(Array(words[i..<(i + n)]))
                i += n
            }
        }
    }
}

extension XCTestCase {
    /// Spin the main run loop until `condition` holds or `timeout` passes.
    func spinUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
