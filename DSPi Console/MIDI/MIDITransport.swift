//
//  MIDITransport.swift
//  DSPi Console
//
//  A DeviceTransport over the DSPi's USB MIDI control channel: the firmware's
//  "DSPi Control" MIDI port carries the same vendor requests as the USB
//  vendor interface, one SysEx message per request or reply (wire format in
//  MIDIControlCodec.swift).  It is the USB transport on iPhone and iPad,
//  which cannot open the vendor interface, and an alternative on macOS.
//  Specification: dspi-ios docs/MIDI-TRANSPORT-SWIFT.md (work package H2).
//
//  * One request in flight.  SETs are queued (fire and forget) and GETs block
//    their caller, both on one serial queue, so they reach the device in the
//    order the console issued them, as on the USB path.
//  * Replies are matched by tag (1...0x7E, rotating); a reply with tag 0x7F
//    is the device's error answer to whatever is in flight.  Late replies to
//    a request that timed out carry an old tag and are dropped.
//  * Timeouts 2 s, 5 s for the bulk requests (as DSPi Link).  BUSY,
//    BULK_LOCKED and CRC_ERROR mean the device did not act; they are retried
//    a few times with a short backoff.
//  * Notifications (tag 0, frame type 0x40) go to `addNotificationObserver`.
//    A change made over MIDI comes back with source PARAM_SRC_MIDI, which
//    only this transport can have caused, so it is attributed to `session`
//    and the view model skips the echo; so is the BULK_SET invalidation of
//    our own bulk write.  A gap in the v2 sequence byte means
//    the device dropped notifications for us: a synthetic BULK_INVALIDATED
//    makes the view model re-read everything (the firmware's recovery rule).
//  * Connecting opens the port and reads REQ_GET_PLATFORM; only an answer
//    makes the transport "connected", and the view model then reads
//    REQ_GET_ALL_PARAMS and the individual GETs.  Every bulk transfer is
//    timed and logged (category MIDITransport), which answers how fast SysEx
//    is on a given host.
//  * Read-only mode (`readOnly`, UserDefaults `MIDIReadOnly`): only requests
//    named GET in the firmware's command table go out; every SET and every
//    write-as-read GET is refused locally.  For monitoring a unit that must
//    not change, and for testing against one.
//

import Foundation
import Combine
import os

final class MIDITransport: DeviceTransport {

    // MARK: - Tunables

    static let requestTimeout: TimeInterval = 2
    static let bulkTimeout: TimeInterval = 5
    /// Retries after BUSY / BULK_LOCKED / CRC_ERROR.
    static let maxRetries = 3
    /// This many timeouts in a row and the link is declared dead.
    static let deadAfterTimeouts = 3

    private static let log = Logger(subsystem: "WeebLabs.DSPi-Console", category: "MIDITransport")

    // MARK: - DeviceTransport state

    /// The only host on this MIDI link, like USB: session 1.
    let session: LinkSessionID = 1
    var generation: UInt64 { stateLock.lock(); defer { stateLock.unlock() }; return _generation }

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let devicesSubject = CurrentValueSubject<[DSPiDevice], Never>([])
    private let selectedSubject = CurrentValueSubject<DSPiDevice?, Never>(nil)
    private let errorSubject = CurrentValueSubject<String?, Never>(nil)
    private let fanout = NotificationFanout()

    var isConnected: Bool { connectedSubject.value }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var availableDevices: [DSPiDevice] { devicesSubject.value }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { devicesSubject.eraseToAnyPublisher() }
    var selectedDevice: DSPiDevice? { selectedSubject.value }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { selectedSubject.eraseToAnyPublisher() }
    var errorMessage: String? { errorSubject.value }
    var errorMessagePublisher: AnyPublisher<String?, Never> { errorSubject.eraseToAnyPublisher() }

    // MARK: - Configuration

    let port: MIDIControlPort
    let manufacturer: [UInt8]
    let readOnly: Bool
    private let autoSelect: Bool
    /// Seconds; tests shorten them.
    var requestTimeout: TimeInterval
    var bulkTimeout: TimeInterval

    // MARK: - Request engine

    /// Runs one transaction at a time, in submission order.
    private let requestQueue = DispatchQueue(label: "WeebLabs.DSPi-Console.MIDITransport", qos: .userInitiated)
    /// Guards everything below and the generation.
    private let stateLock = NSLock()
    private var _generation: UInt64 = 0
    private var endpointsBySerial: [String: MIDIControlEndpoint] = [:]
    private var knownSerials: Set<String> = []
    private var openEndpoint: MIDIControlEndpoint?
    /// Random start, so two hosts on one port (each sees the other's
    /// replies) are unlikely to use the same tag at the same time.
    private var nextTag = UInt8.random(in: 0..<0x7E)
    private var inFlight: InFlight?
    private var consecutiveTimeouts = 0
    private var lastNotifySeq: UInt8?
    private var refusedReadOnly: Set<UInt8> = []
    /// Until when a BULK_INVALIDATED with source BULK_SET is the result of
    /// our own bulk write (see `notify`).
    private var ownBulkWriteUntil = Date.distantPast
    private var _stats = Stats()

    /// Touched only from the port's receive thread.
    private var assembler = SysExAssembler()

    private final class InFlight {
        let tag: UInt8
        let semaphore = DispatchSemaphore(value: 0)
        var reply: MIDIControlCodec.DeviceFrame?
        init(tag: UInt8) { self.tag = tag }
    }

    // MARK: - Statistics

    struct Timing {
        var count = 0
        var total: TimeInterval = 0
        var min: TimeInterval = .infinity
        var max: TimeInterval = 0
        var mean: TimeInterval { count == 0 ? 0 : total / Double(count) }
        mutating func add(_ t: TimeInterval) {
            count += 1; total += t
            min = Swift.min(min, t); max = Swift.max(max, t)
        }
    }

    struct Stats {
        var requests = 0
        var timeouts = 0
        var retries = 0
        var staleReplies = 0
        var foreignSysEx = 0
        var malformed = 0
        var badFrames = 0
        var notifications = 0
        var sequenceGaps = 0
        var refusedReadOnly = 0
        /// Round trip of every completed transaction, by bRequest.
        var roundTrip: [UInt8: Timing] = [:]
        /// REQ_GET_ALL_PARAMS: (bytes, seconds) of the most recent reads.
        var bulkReads: [(bytes: Int, seconds: TimeInterval)] = []
    }

    var stats: Stats { stateLock.lock(); defer { stateLock.unlock() }; return _stats }

    // MARK: - Init

    /// - Parameters:
    ///   - port: the MIDI port; CoreMIDI by default.
    ///   - autoSelect: open the first DSPi that appears when nothing is
    ///     selected, as the USB transport does.
    ///   - readOnly: refuse every request that could change the device.
    init(port: MIDIControlPort = CoreMIDIControlPort(),
         manufacturer: [UInt8] = MIDIControlCodec.developmentManufacturer,
         autoSelect: Bool = true,
         readOnly: Bool = UserDefaults.standard.bool(forKey: "MIDIReadOnly"),
         requestTimeout: TimeInterval = MIDITransport.requestTimeout,
         bulkTimeout: TimeInterval = MIDITransport.bulkTimeout) {
        self.port = port
        self.requestTimeout = requestTimeout
        self.bulkTimeout = bulkTimeout
        self.manufacturer = manufacturer
        self.autoSelect = autoSelect
        self.readOnly = readOnly
        port.onReceive = { [weak self] words in self?.receive(words) }
        port.onEndpointsChanged = { [weak self] in self?.endpointsChanged() }
        if let reason = port.unavailableReason { errorSubject.send(reason) }
        if readOnly { Self.log.notice("MIDI transport is read-only") }
        endpointsChanged()
    }

    // MARK: - Devices and connection

    private static func device(for endpoint: MIDIControlEndpoint) -> DSPiDevice {
        let name = endpoint.serial.hasPrefix("RELAY-")
            ? "DSPi via MIDI relay \(endpoint.serial.dropFirst(6))"
            : "DSPi (\(endpoint.serial.suffix(8))) via USB MIDI"
        return DSPiDevice(serial: endpoint.serial, locationID: endpoint.locationID, hub: nil, remoteName: name)
    }

    /// Hot-plug: refresh the list, drop a vanished device, open a new one.
    private func endpointsChanged() {
        let endpoints = port.endpoints
        stateLock.lock()
        endpointsBySerial = Dictionary(endpoints.map { ($0.serial, $0) }, uniquingKeysWith: { a, _ in a })
        let open = openEndpoint
        stateLock.unlock()
        devicesSubject.send(endpoints.map(Self.device(for:)))

        if let open = open, !endpoints.contains(where: { $0.serial == open.serial }) {
            Self.log.notice("DSPi MIDI port \(open.name, privacy: .public) went away")
            disconnect()
        } else if let open = open, let now = endpoints.first(where: { $0.serial == open.serial }), now != open {
            // Same device, new endpoint objects (replugged faster than the
            // removal was seen): reopen.
            connectedSubject.send(false)
            openPort(Self.device(for: now), force: true)
        }
        // Only a device that just appeared is opened by itself, so a device
        // the user let go of (or switched away from) stays closed.
        stateLock.lock()
        let fresh = endpoints.filter { !knownSerials.contains($0.serial) }
        knownSerials = Set(endpoints.map { $0.serial })
        stateLock.unlock()
        if autoSelect, selectedDevice == nil, let first = fresh.first {
            selectDevice(Self.device(for: first))
        }
    }

    func selectDevice(_ device: DSPiDevice) {
        openPort(device, force: false)
    }

    /// Open `device`'s port and probe it.  Selecting the device that is
    /// already open (the view model re-selects at start-up) keeps the port
    /// and the probe in progress: reopening would drop a reply in flight.
    private func openPort(_ device: DSPiDevice, force: Bool) {
        stateLock.lock()
        let endpoint = endpointsBySerial[device.serial]
        let alreadyOpen = endpoint != nil && openEndpoint == endpoint
        stateLock.unlock()
        guard let endpoint = endpoint else { return }
        if alreadyOpen && !force {
            selectedSubject.send(device)
            return
        }
        closePort()
        guard port.open(endpoint) else {
            selectedSubject.send(device)
            errorSubject.send("Could not open the DSPi's MIDI port \(endpoint.name).")
            return
        }
        stateLock.lock()
        _generation &+= 1
        let generation = _generation
        openEndpoint = endpoint
        consecutiveTimeouts = 0
        lastNotifySeq = nil
        stateLock.unlock()
        selectedSubject.send(device)
        errorSubject.send(nil)
        Self.log.notice("Opened DSPi MIDI port \(endpoint.name, privacy: .public) [\(endpoint.serial, privacy: .public)]")

        // Prove the device answers before calling it connected: a port can
        // exist on firmware that ignores our SysEx (wrong manufacturer ID).
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            var result: Result<[UInt8], LinkStatus> = .failure(.noDevice)
            for _ in 0..<3 {
                result = self.transact(type: MIDIControlCodec.typeGet, request: REQ_GET_PLATFORM,
                                       value: 0, index: 2, length: 7, payload: [])
                if case .success = result { break }
                if self.generation != generation { return }
            }
            DispatchQueue.main.async {
                guard self.generation == generation else { return }
                switch result {
                case .success(let platform):
                    Self.log.notice("DSPi on MIDI answered, platform \(platform.map { String(format: "%02X", $0) }.joined(separator: " "), privacy: .public)")
                    self.connectedSubject.send(true)
                case .failure(let status):
                    Self.log.error("DSPi MIDI port does not answer REQ_GET_PLATFORM: \(String(describing: status), privacy: .public)")
                    self.errorSubject.send("The DSPi's MIDI port does not answer (\(status)).")
                }
            }
        }
    }

    func reconnect() {
        guard let device = selectedDevice else { return }
        connectedSubject.send(false)
        openPort(device, force: true)
    }

    func disconnect() {
        closePort()
        connectedSubject.send(false)
        selectedSubject.send(nil)
    }

    /// The app is back in the foreground.  iOS suspends a background app,
    /// so nothing was read meanwhile and the device may have dropped
    /// notifications for us: check that it still answers, then have the view
    /// model re-read everything (a synthetic BULK_INVALIDATED), or reconnect
    /// if it does not answer.
    func resume() {
        guard let device = selectedDevice else { return }
        guard isConnected else { reconnect(); return }
        let generation = self.generation
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.transact(type: MIDIControlCodec.typeGet, request: REQ_GET_PLATFORM,
                                       value: 0, index: 2, length: 7, payload: [])
            DispatchQueue.main.async {
                guard self.generation == generation, self.selectedDevice == device else { return }
                if case .success = result {
                    self.stateLock.lock(); self.lastNotifySeq = nil; self.stateLock.unlock()
                    Self.log.notice("Resumed: DSPi still answers, re-reading state")
                    self.fanout.publish(LinkNotification(packet: Self.syntheticBulkInvalidated, origin: 0, receivedAt: Date()))
                } else {
                    Self.log.notice("Resumed: DSPi does not answer, reconnecting")
                    self.reconnect()
                }
            }
        }
    }

    func markDisconnected() {
        connectedSubject.send(false)
    }

    private func closePort() {
        stateLock.lock()
        let wasOpen = openEndpoint != nil
        openEndpoint = nil
        _generation &+= 1
        let waiting = inFlight
        inFlight = nil
        stateLock.unlock()
        waiting?.semaphore.signal()
        if wasOpen { port.close() }
    }

    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        fanout.add(handler)
    }

    // MARK: - Requests

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        guard permitted(isGet: false, request: request) else { return }
        let payload = [UInt8](data)
        requestQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.transact(type: MIDIControlCodec.typeSet, request: request, value: value,
                                       index: index, length: UInt16(truncatingIfNeeded: payload.count),
                                       payload: payload)
            if case .failure(let status) = result {
                Self.log.error("SET 0x\(String(format: "%02X", request), privacy: .public) failed: \(String(describing: status), privacy: .public)")
            }
        }
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        guard permitted(isGet: true, request: request) else { return .failure(.denied) }
        let result = requestQueue.sync {
            transact(type: MIDIControlCodec.typeGet, request: request, value: value, index: index,
                     length: length, payload: [])
        }
        return result.map { Data($0) }
    }

    /// Read-only mode's filter.  Logs each refused opcode once.
    private func permitted(isGet: Bool, request: UInt8) -> Bool {
        guard readOnly else { return true }
        if isGet && Self.pureReads.contains(request) { return true }
        stateLock.lock()
        _stats.refusedReadOnly += 1
        let first = refusedReadOnly.insert(request).inserted
        stateLock.unlock()
        if first {
            Self.log.notice("Read-only: refused \(isGet ? "GET" : "SET", privacy: .public) 0x\(String(format: "%02X", request), privacy: .public)")
        }
        return false
    }

    /// The requests the firmware's command table (config.h) names GET, i.e.
    /// those that only read.  Write-as-read GETs (preset save/load/delete,
    /// save, factory reset, pin moves, bootloader, siggen and RTA control,
    /// stats resets, ...) are not in it.
    static let pureReads: Set<UInt8> = [
        0x05, 0x07, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0F, 0x11, 0x13, 0x15, 0x17, 0x19, 0x1A, 0x1C, 0x1E,
        0x1F, 0x21, 0x23, 0x26, 0x28, 0x2A, 0x2B, 0x2D, 0x2F, 0x31, 0x33, 0x35, 0x37, 0x39, 0x3B, 0x3D,
        0x3F, 0x43, 0x45, 0x47, 0x49, 0x4B, 0x4D, 0x4E, 0x50, 0x55, 0x57, 0x59, 0x5B, 0x5D, 0x5F, 0x61,
        0x63, 0x65, 0x67, 0x69, 0x6B, 0x6D, 0x6E, 0x71, 0x73, 0x75, 0x77, 0x79, 0x7A, 0x7B, 0x7D, 0x7E,
        0x7F, 0x80, 0x82, 0x85, 0x86, 0x87, 0x89, 0x8A, 0x8C, 0x8E, 0x93, 0x95, 0x97, 0x99, 0x9A, 0x9C,
        0xA0, 0xA2, 0xA5, 0xA7, 0xA8, 0xAA, 0xAC, 0xAE, 0xB0, 0xB2, 0xB5, 0xB7, 0xB9, 0xBB, 0xBD, 0xBF,
        0xC1, 0xC3, 0xC5, 0xC7, 0xC9, 0xCB, 0xCD, 0xCE, 0xD1, 0xD3, 0xD5, 0xD7, 0xD9, 0xDB, 0xDD, 0xDF,
        0xE1, 0xE2, 0xE3, 0xE5, 0xE7, 0xE8, 0xEB, 0xEE, 0xEF, 0xF2, 0xF4, 0xF6, 0xF8, 0xF9, 0xFB, 0xFD,
        0xFF,
    ]

    private static func isBulk(_ request: UInt8) -> Bool {
        request == REQ_GET_ALL_PARAMS || request == REQ_SET_ALL_PARAMS || request == 0xA2 || request == 0xA3
    }

    /// One request with retries.  Runs on `requestQueue` only.
    private func transact(type: UInt8, request: UInt8, value: UInt16, index: UInt16,
                          length: UInt16, payload: [UInt8]) -> Result<[UInt8], LinkStatus> {
        let frame = MIDIControlCodec.requestFrame(type: type, request: request, value: value, index: index,
                                                  length: length, payload: payload)
        let timeout = Self.isBulk(request) ? bulkTimeout : requestTimeout
        let isBulkWrite = type == MIDIControlCodec.typeSet && (request == REQ_SET_ALL_PARAMS || request == 0xA3)
        if isBulkWrite {
            stateLock.lock(); ownBulkWriteUntil = .distantFuture; stateLock.unlock()
        }
        defer {
            if isBulkWrite {
                stateLock.lock(); ownBulkWriteUntil = Date().addingTimeInterval(1); stateLock.unlock()
            }
        }
        var attempt = 0
        while true {
            let started = Date()
            let result = exchange(frame: frame, timeout: timeout)
            let elapsed = Date().timeIntervalSince(started)
            switch result {
            case .success(let reply):
                let expected = type == MIDIControlCodec.typeGet ? MIDIControlCodec.typeGetReply : MIDIControlCodec.typeSetReply
                let status = LinkStatus(rawValue: reply.status) ?? .error
                if reply.type != expected && status == .ok {
                    stateLock.lock(); _stats.badFrames += 1; stateLock.unlock()
                    return .failure(.frameError)
                }
                if (status == .busy || status == .bulkLocked || status == .crcError) && attempt < Self.maxRetries {
                    attempt += 1
                    stateLock.lock(); _stats.retries += 1; stateLock.unlock()
                    Thread.sleep(forTimeInterval: 0.02 * Double(attempt))
                    continue
                }
                stateLock.lock()
                _stats.roundTrip[request, default: Timing()].add(elapsed)
                if request == REQ_GET_ALL_PARAMS && status == .ok {
                    _stats.bulkReads.append((reply.payload.count, elapsed))
                    if _stats.bulkReads.count > 50 { _stats.bulkReads.removeFirst() }
                }
                stateLock.unlock()
                if Self.isBulk(request) {
                    let isSet = type == MIDIControlCodec.typeSet
                    let sent = isSet ? payload.count : reply.payload.count
                    // The long direction's message: F0, ID, "DSP", ver, tag, packed frame, F7.
                    let frameBytes = isSet ? frame.count : 4 + reply.payload.count + 2
                    let sysex = manufacturer.count + 6 + MIDIControlCodec.packedLength(frameBytes) + 1
                    Self.log.notice("\(type == MIDIControlCodec.typeGet ? "GET" : "SET", privacy: .public) 0x\(String(format: "%02X", request), privacy: .public): \(sent) B (\(sysex) B SysEx) in \(String(format: "%.1f", elapsed * 1000), privacy: .public) ms, \(String(format: "%.0f", Double(sysex) / max(elapsed, 1e-6) / 1000), privacy: .public) kB/s, status \(String(describing: status), privacy: .public)")
                }
                return status == .ok ? .success(reply.payload) : .failure(status)
            case .failure(let status):
                return .failure(status)
            }
        }
    }

    /// Send one frame and wait for its reply.  Runs on `requestQueue` only.
    private func exchange(frame: [UInt8], timeout: TimeInterval) -> Result<MIDIControlCodec.DeviceFrame, LinkStatus> {
        stateLock.lock()
        guard openEndpoint != nil else { stateLock.unlock(); return .failure(.noDevice) }
        nextTag = nextTag % 0x7E + 1                 // 1...0x7E
        let pending = InFlight(tag: nextTag)
        inFlight = pending
        _stats.requests += 1
        let generation = _generation
        stateLock.unlock()

        let words = MIDIUMPSysEx.words(forSysEx: MIDIControlCodec.encode(frame: frame, tag: pending.tag,
                                                                          manufacturer: manufacturer))
        guard port.send(words) else {
            stateLock.lock(); if inFlight === pending { inFlight = nil }; stateLock.unlock()
            return .failure(.noDevice)
        }
        let waited = pending.semaphore.wait(timeout: .now() + timeout)

        stateLock.lock()
        if inFlight === pending { inFlight = nil }
        let reply = pending.reply
        let sameDevice = generation == _generation
        var declareDead = false
        if reply == nil && sameDevice && waited == .timedOut {
            _stats.timeouts += 1
            consecutiveTimeouts += 1
            declareDead = consecutiveTimeouts == Self.deadAfterTimeouts
        } else if reply != nil {
            consecutiveTimeouts = 0
        }
        stateLock.unlock()

        guard let r = reply else {
            if !sameDevice { return .failure(.noDevice) }
            Self.log.error("No reply to tag \(pending.tag) within \(timeout) s")
            if declareDead {
                Self.log.error("\(Self.deadAfterTimeouts) timeouts in a row: DSPi MIDI link is down")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == generation else { return }
                    self.errorSubject.send("The DSPi stopped answering on MIDI.")
                    self.connectedSubject.send(false)
                }
            }
            return .failure(.timeout)
        }
        return .success(r)
    }

    // MARK: - Receive path (port thread)

    private func receive(_ words: [UInt32]) {
        for message in assembler.feed(words) {
            handle(message)
        }
    }

    private func handle(_ message: [UInt8]) {
        let decoded: (tag: UInt8, frame: [UInt8])
        switch MIDIControlCodec.decode(message, manufacturer: manufacturer) {
        case .success(let d): decoded = d
        case .failure(.notOurs):
            stateLock.lock(); _stats.foreignSysEx += 1; stateLock.unlock()
            return
        case .failure(.malformed):
            stateLock.lock(); _stats.malformed += 1; stateLock.unlock()
            return
        }
        guard let frame = MIDIControlCodec.parseDeviceFrame(decoded.frame) else {
            stateLock.lock(); _stats.badFrames += 1; stateLock.unlock()
            return
        }
        if frame.type == MIDIControlCodec.typeNotify {
            notify(frame.payload)
            return
        }
        stateLock.lock()
        if let pending = inFlight, decoded.tag == pending.tag || decoded.tag == MIDIControlCodec.tagUnknown {
            inFlight = nil
            pending.reply = frame
            stateLock.unlock()
            pending.semaphore.signal()
        } else {
            _stats.staleReplies += 1
            stateLock.unlock()
        }
    }

    /// v2 BULK_INVALIDATED, source UNKNOWN: version, event, flags, seq,
    /// source, reserved x3 (as HubTransport's resync).
    private static let syntheticBulkInvalidated = Data([0x02, 0x03, 0, 0, 0, 0, 0, 0])

    private func notify(_ packet: [UInt8]) {
        guard packet.count >= 4, packet[0] == 0x02 else { return }     // v2 only
        let seq = packet[3]
        stateLock.lock()
        _stats.notifications += 1
        let gap = lastNotifySeq.map { seq != $0 &+ 1 } ?? false
        lastNotifySeq = seq
        if gap { _stats.sequenceGaps += 1 }
        stateLock.unlock()

        let data = Data(packet)
        let source = Self.sourceByte(of: data)
        // The firmware tags a bulk apply BULK_SET whichever transport sent
        // it; one that lands while our own 0xA1 / 0xA3 is in flight, or just
        // after, is ours (the bulk lock keeps other hosts' bulk writes out
        // of that window).
        stateLock.lock(); let ownBulk = Date() < ownBulkWriteUntil; stateLock.unlock()
        let ours = source == Self.paramSourceMIDI || (packet[1] == 0x03 && source == Self.paramSourceBulkSet && ownBulk)
        let note = LinkNotification(packet: data, origin: ours ? session : 0, receivedAt: Date())
        fanout.publish(note)
        if gap {
            Self.log.notice("Notification sequence gap before seq \(seq): re-reading state")
            fanout.publish(LinkNotification(packet: Self.syntheticBulkInvalidated, origin: 0, receivedAt: Date()))
        }
    }

    /// PARAM_SRC_MIDI: changes made through this channel.
    static let paramSourceMIDI: UInt8 = 10
    /// PARAM_SRC_BULK_SET: a REQ_SET_ALL_PARAMS applied, from any transport.
    static let paramSourceBulkSet: UInt8 = 2

    /// The ParamSource byte where each event puts it (see
    /// LinkNotification.isHostSourced), or nil.
    private static func sourceByte(of packet: Data) -> UInt8? {
        guard packet.count > 1 else { return nil }
        let offset: Int
        switch packet[packet.startIndex + 1] {
        case 0x02, 0x0C: offset = 8
        case 0x03: offset = 4
        case NOTIFY_EVT_RTA_CONFIG: offset = 16
        default: return nil
        }
        guard packet.count > offset else { return nil }
        return packet[packet.startIndex + offset]
    }

    // MARK: - Diagnostics

    /// One line per request kind, for logs and the hardware test.
    func statsSummary() -> String {
        let s = stats
        var lines = ["requests \(s.requests), timeouts \(s.timeouts), retries \(s.retries), stale \(s.staleReplies), malformed \(s.malformed), bad frames \(s.badFrames), foreign \(s.foreignSysEx), notifications \(s.notifications), seq gaps \(s.sequenceGaps), refused (read-only) \(s.refusedReadOnly)"]
        for (request, t) in s.roundTrip.sorted(by: { $0.key < $1.key }) {
            lines.append(String(format: "0x%02X: n=%d mean %.2f ms min %.2f max %.2f", request, t.count,
                                t.mean * 1000, t.min * 1000, t.max * 1000))
        }
        return lines.joined(separator: "\n")
    }
}
