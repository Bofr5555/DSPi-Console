//
//  MIDIControlPort.swift
//  DSPi Console
//
//  The CoreMIDI side of the MIDI transport: finds the DSPi's "DSPi Control"
//  port, opens it, and moves UMP words in and out.  It knows nothing about
//  the control protocol; `MIDITransport` owns the codec, the SysEx
//  reassembly and the request queue, so tests can replace this layer with a
//  fake that speaks the protocol.
//
//  CoreMIDI is the same API on macOS and iOS.  On macOS it works only inside
//  a logged-in GUI session (a bare ssh shell sees no devices).
//

import Foundation
import CoreMIDI
import os

/// One DSPi control port: a source (device to host) and a destination (host
/// to device) on the same USB MIDI entity.
struct MIDIControlEndpoint: Equatable {
    /// USB serial number when CoreMIDI knows it (the USB driver publishes it
    /// on the device), otherwise a stable stand-in from the source's unique id.
    let serial: String
    /// USB location id when known (the same number IOKit reports), else 0.
    let locationID: UInt32
    /// CoreMIDI display name, for logs and pickers.
    let name: String
    let sourceID: MIDIUniqueID
    let destinationID: MIDIUniqueID
}

/// What `MIDITransport` needs from a MIDI port.  The CoreMIDI implementation
/// is `CoreMIDIControlPort`; the tests use a fake.
protocol MIDIControlPort: AnyObject {
    /// DSPi control ports present now.
    var endpoints: [MIDIControlEndpoint] { get }
    /// Called on the main thread after `endpoints` changed (hot-plug).
    var onEndpointsChanged: (() -> Void)? { get set }
    /// Called with the UMP words of each received event packet, in order, on
    /// one thread at a time (any thread).  Only the open endpoint delivers.
    var onReceive: (([UInt32]) -> Void)? { get set }
    /// Why MIDI is unusable (no CoreMIDI client), or nil.
    var unavailableReason: String? { get }

    /// Start receiving from `endpoint` and send to it; closes any other.
    func open(_ endpoint: MIDIControlEndpoint) -> Bool
    func close()
    /// Send complete UMP messages to the open endpoint.  False when nothing is
    /// open or CoreMIDI refused.
    func send(_ words: [UInt32]) -> Bool
}

final class CoreMIDIControlPort: MIDIControlPort {

    /// Endpoint name the firmware gives its MIDI interface (string
    /// descriptor of the MIDIStreaming interface).
    static let controlPortName = "DSPi Control"

    private static let log = Logger(subsystem: "WeebLabs.DSPi-Console", category: "MIDITransport")

    var onEndpointsChanged: (() -> Void)?
    var onReceive: (([UInt32]) -> Void)?
    private(set) var unavailableReason: String?

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private let lock = NSLock()
    private var _endpoints: [MIDIControlEndpoint] = []
    private var openSource = MIDIEndpointRef()
    private var openDestination = MIDIEndpointRef()
    private var rescanQueued = false

    /// Extra name to accept besides "DSPi Control" (UserDefaults
    /// `MIDIControlEndpoint`): a substring of an endpoint's display name, for
    /// a DSPi reached through a CoreMIDI network session, whose endpoints are
    /// named after the session.
    private let extraName: String?

    var endpoints: [MIDIControlEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return _endpoints
    }

    init(clientName: String = "DSPi Console", extraName: String? = UserDefaults.standard.string(forKey: "MIDIControlEndpoint")) {
        self.extraName = (extraName?.isEmpty ?? true) ? nil : extraName
        var status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] note in
            switch note.pointee.messageID {
            case .msgObjectAdded, .msgObjectRemoved, .msgSetupChanged, .msgPropertyChanged:
                self?.scheduleRescan()
            default:
                break
            }
        }
        guard status == noErr else {
            unavailableReason = "CoreMIDI is not available (MIDIClientCreate \(status))."
            Self.log.error("MIDIClientCreate failed: \(status)")
            return
        }
        status = MIDIInputPortCreateWithProtocol(client, "DSPi Control in" as CFString, ._1_0, &inPort) {
            [weak self] list, _ in
            self?.received(list)
        }
        if status == noErr {
            status = MIDIOutputPortCreate(client, "DSPi Control out" as CFString, &outPort)
        }
        guard status == noErr else {
            unavailableReason = "CoreMIDI ports could not be created (\(status))."
            Self.log.error("MIDI port creation failed: \(status)")
            return
        }
        rescan()
    }

    deinit {
        close()
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Discovery

    /// CoreMIDI posts several notifications per plug event; scan once after them.
    private func scheduleRescan() {
        lock.lock()
        let queued = rescanQueued
        rescanQueued = true
        lock.unlock()
        guard !queued else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.rescanQueued = false; self.lock.unlock()
            self.rescan()
            self.onEndpointsChanged?()
        }
    }

    private func rescan() {
        var found: [MIDIControlEndpoint] = []
        let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard isDSPiControl(source), let destination = partner(of: source, in: destinations) else { continue }
            let device = Self.device(of: source)
            let sourceID = Self.int(source, kMIDIPropertyUniqueID) ?? 0
            let serial = device.flatMap { Self.string($0, "SerialNumber" as CFString) }
                ?? String(format: "MIDI-%08X", UInt32(bitPattern: sourceID))
            let location = device.flatMap { Self.int($0, "USBLocationID" as CFString) } ?? 0
            found.append(MIDIControlEndpoint(
                serial: serial, locationID: UInt32(bitPattern: location),
                name: Self.string(source, kMIDIPropertyDisplayName) ?? Self.controlPortName,
                sourceID: sourceID, destinationID: Self.int(destination, kMIDIPropertyUniqueID) ?? 0))
        }
        lock.lock(); let changed = found != _endpoints; _endpoints = found; lock.unlock()
        if changed {
            Self.log.notice("DSPi MIDI control ports: \(found.map { "\($0.name) [\($0.serial)]" }.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The DSPi's control endpoint: named "DSPi Control" on a device (or a
    /// virtual endpoint) that says it is a Weeb Labs DSPi.  Endpoints inherit
    /// manufacturer and model from their device.
    private func isDSPiControl(_ endpoint: MIDIEndpointRef) -> Bool {
        if Self.int(endpoint, kMIDIPropertyOffline) == 1 { return false }
        let name = Self.string(endpoint, kMIDIPropertyName) ?? ""
        let display = Self.string(endpoint, kMIDIPropertyDisplayName) ?? name
        if let extra = extraName, display.localizedCaseInsensitiveContains(extra) { return true }
        guard name.contains(Self.controlPortName) || display.contains(Self.controlPortName) else { return false }
        let manufacturer = Self.string(endpoint, kMIDIPropertyManufacturer) ?? ""
        let model = Self.string(endpoint, kMIDIPropertyModel) ?? ""
        return manufacturer.contains("WeebLabs") || manufacturer.contains("Weeb Labs") || model.contains("DSPi")
    }

    /// The destination on the same entity, or for virtual endpoints (no
    /// entity) the one with the same name.
    private func partner(of source: MIDIEndpointRef, in destinations: [MIDIEndpointRef]) -> MIDIEndpointRef? {
        var entity = MIDIEntityRef()
        if MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0 {
            for d in destinations {
                var e = MIDIEntityRef()
                if MIDIEndpointGetEntity(d, &e) == noErr, e == entity { return d }
            }
            return nil
        }
        let name = Self.string(source, kMIDIPropertyName)
        return destinations.first { d in
            var e = MIDIEntityRef()
            return (MIDIEndpointGetEntity(d, &e) != noErr || e == 0) && Self.string(d, kMIDIPropertyName) == name
        }
    }

    private static func device(of endpoint: MIDIEndpointRef) -> MIDIDeviceRef? {
        var entity = MIDIEntityRef(), device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0,
              MIDIEntityGetDevice(entity, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private static func string(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func int(_ object: MIDIObjectRef, _ key: CFString) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, key, &value) == noErr else { return nil }
        return value
    }

    private static func endpoint(withID id: MIDIUniqueID) -> MIDIEndpointRef? {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(id, &object, &type) == noErr, object != 0 else { return nil }
        return object
    }

    // MARK: - I/O

    func open(_ endpoint: MIDIControlEndpoint) -> Bool {
        close()
        guard unavailableReason == nil,
              let source = Self.endpoint(withID: endpoint.sourceID),
              let destination = Self.endpoint(withID: endpoint.destinationID) else { return false }
        let status = MIDIPortConnectSource(inPort, source, nil)
        guard status == noErr else {
            Self.log.error("MIDIPortConnectSource failed: \(status)")
            return false
        }
        lock.lock(); openSource = source; openDestination = destination; lock.unlock()
        return true
    }

    func close() {
        lock.lock()
        let source = openSource
        openSource = 0; openDestination = 0
        lock.unlock()
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
    }

    func send(_ words: [UInt32]) -> Bool {
        lock.lock(); let destination = openDestination; lock.unlock()
        guard destination != 0, !words.isEmpty else { return false }
        let status = Self.withEventList(words) { MIDISendEventList(outPort, destination, $0) }
        if status != noErr { Self.log.error("MIDISendEventList failed: \(status)") }
        return status == noErr
    }

    /// Builds a MIDI 1.0 protocol event list holding `words` (complete UMP
    /// messages, all at time 0) and hands it to `body`.  -1 if the words do
    /// not fit, which the sizing below rules out.
    static func withEventList(_ words: [UInt32], _ body: (UnsafePointer<MIDIEventList>) -> OSStatus) -> OSStatus {
        // Room for the words plus one packet header (timestamp, count) per
        // 64-word packet and the list header.
        let size = 64 + words.count * 4 + (words.count / 32 + 2) * 16
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        let ok: Bool = words.withUnsafeBufferPointer { buffer in
            var i = 0
            while i < buffer.count {
                let n = min(MIDIUMPSysEx.messageWordCount(buffer[i]), buffer.count - i)
                // The SDK imports the result as non-optional, but it is NULL
                // when the list is full.
                let next = MIDIEventListAdd(list, size, packet, 0, n, buffer.baseAddress! + i)
                guard UInt(bitPattern: next) != 0 else { return false }
                packet = next
                i += n
            }
            return true
        }
        guard ok else {
            log.error("MIDI event list overflow (\(words.count) words)")
            return -1
        }
        return body(list)
    }

    private func received(_ list: UnsafePointer<MIDIEventList>) {
        guard let handler = onReceive else { return }
        for packet in list.unsafeSequence() {
            let words = Self.words(of: packet)
            if !words.isEmpty { handler(words) }
        }
    }

    /// A packet's words.  `MIDIEventPacket.words` is declared as 64 words,
    /// but CoreMIDI packs longer packets (a 7 KB SysEx arrives in packets of
    /// about 230 words), so copying the tuple would cut them short: read
    /// `wordCount` words from the packet's memory instead.
    static func words(of packet: UnsafePointer<MIDIEventPacket>) -> [UInt32] {
        let count = Int(packet.pointee.wordCount)
        guard count > 0, let offset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) else { return [] }
        let base = UnsafeRawPointer(packet).advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: base, count: count))
    }
}
