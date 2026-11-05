//
//  MIDIRelayPort.swift
//  DSPi Console
//
//  A MIDIControlPort that reaches a DSPi through a relay on another
//  machine instead of CoreMIDI: the relay (dspi-ios tools/midi-relay,
//  `macrelay`) holds the DSPi's "DSPi Control" endpoints and forwards UMP
//  words both ways over TCP, framed as <u32 LE word count><words LE>.
//
//  The iOS Simulator has its own CoreMIDI, which cannot see the Mac's USB
//  devices and refuses virtual endpoints to apps without the audio
//  background mode, so this is how the simulator app talks to a real DSPi:
//  everything above the port (codec, reassembly, request queue,
//  notifications, the console) is the code a device runs.  Used only when
//  launched with `-MIDIRelay host:port`; a development aid, not a product
//  transport.
//

import Foundation
import os

final class MIDIRelayPort: MIDIControlPort {

    /// The relay named by UserDefaults `MIDIRelay` ("host:port"), or nil.
    static func fromDefaults() -> MIDIRelayPort? {
        guard let spec = UserDefaults.standard.string(forKey: "MIDIRelay"), !spec.isEmpty else { return nil }
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        return MIDIRelayPort(host: String(parts[0]), port: port)
    }

    private static let log = Logger(subsystem: "WeebLabs.DSPi-Console", category: "MIDITransport")

    let host: String
    let port: UInt16
    var onEndpointsChanged: (() -> Void)?
    var onReceive: (([UInt32]) -> Void)?
    let unavailableReason: String? = nil

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var opened = false
    private var connected = false

    private var endpoint: MIDIControlEndpoint {
        MIDIControlEndpoint(serial: "RELAY-\(host):\(port)", locationID: 0,
                            name: "DSPi Control via relay \(host):\(port)", sourceID: 1, destinationID: 2)
    }

    var endpoints: [MIDIControlEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return connected ? [endpoint] : []
    }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        let thread = Thread { [weak self] in self?.connectLoop() }
        thread.name = "MIDIRelayPort"
        thread.start()
    }

    // MARK: - Connection

    /// Connect, read until the relay goes away, retry every 2 s.
    private func connectLoop() {
        while true {
            if let sock = dial() {
                lock.lock(); fd = sock; connected = true; lock.unlock()
                Self.log.notice("MIDI relay \(self.host, privacy: .public):\(self.port) connected")
                DispatchQueue.main.async { self.onEndpointsChanged?() }
                readLoop(sock)
                lock.lock(); fd = -1; connected = false; lock.unlock()
                Darwin.close(sock)
                Self.log.notice("MIDI relay \(self.host, privacy: .public):\(self.port) closed")
                DispatchQueue.main.async { self.onEndpointsChanged?() }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func dial() -> Int32? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let ai = info else { return nil }
        defer { freeaddrinfo(info) }
        let sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard sock >= 0 else { return nil }
        guard connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { Darwin.close(sock); return nil }
        var one: Int32 = 1
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return sock
    }

    private func readExactly(_ sock: Int32, _ n: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: n)
        var done = 0
        while done < n {
            let r = buffer.withUnsafeMutableBytes { read(sock, $0.baseAddress! + done, n - done) }
            if r <= 0 { return nil }
            done += r
        }
        return buffer
    }

    private func readLoop(_ sock: Int32) {
        while let head = readExactly(sock, 4) {
            let count = Int(UInt32(head[0]) | UInt32(head[1]) << 8 | UInt32(head[2]) << 16 | UInt32(head[3]) << 24)
            guard count > 0, count < 1 << 20, let body = readExactly(sock, count * 4) else { return }
            var words = [UInt32](repeating: 0, count: count)
            for i in 0..<count {
                let lo = UInt32(body[4 * i]) | UInt32(body[4 * i + 1]) << 8
                words[i] = lo | UInt32(body[4 * i + 2]) << 16 | UInt32(body[4 * i + 3]) << 24
            }
            lock.lock(); let deliver = opened; lock.unlock()
            if deliver { onReceive?(words) }
        }
    }

    // MARK: - MIDIControlPort

    func open(_ endpoint: MIDIControlEndpoint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard connected, endpoint == self.endpoint else { return false }
        opened = true
        return true
    }

    func close() {
        lock.lock(); opened = false; lock.unlock()
    }

    func send(_ words: [UInt32]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard opened, fd >= 0, !words.isEmpty else { return false }
        var frame = [UInt8]()
        frame.reserveCapacity(4 + words.count * 4)
        for v in [UInt32(words.count)] + words { withUnsafeBytes(of: v.littleEndian) { frame += $0 } }
        var done = 0
        while done < frame.count {
            let n = frame.withUnsafeBytes { write(fd, $0.baseAddress! + done, frame.count - done) }
            if n <= 0 { return false }
            done += n
        }
        return true
    }
}
