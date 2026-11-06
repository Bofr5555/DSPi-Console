//
//  FakeTransport.swift
//  DSPi Console
//
//  A simulated DSPi behind the ordinary `DeviceTransport` seam: the demo
//  device of the iOS app ("Demo (no device)"), and a hardware-free transport
//  for previews and tests on either platform.  It answers the same vendor
//  requests a board does, from state seeded by a byte-exact capture of a real
//  unit, so the view model, the decoders and every view run unchanged.
//
//  State
//  -----
//  * `platform.bin` (7 bytes): the REQ_GET_PLATFORM reply of an RP2350 on
//    firmware 1.1.6-beta5.
//  * `bulk_v32.bin` (6136 bytes): that unit's REQ_GET_ALL_PARAMS reply,
//    WireBulkParams V32.  It is the live parameter image: REQ_GET_ALL_PARAMS
//    returns it, REQ_SET_ALL_PARAMS replaces it, and the per-parameter SETs
//    the console sends most (filters, preamp, bypass, delays, matrix, output
//    gain/mute/enable/delay, names, volumes) patch it at their WireBulkParams
//    offsets and emit the v2 PARAM_CHANGED notification a board would.
//  * Ten preset slots, each a saved copy of the image, with names, the
//    directory, startup mode and the active slot.
//  * Everything else the console reads one item at a time is answered from
//    whatever the matching SET last wrote (`echo`), so a value set in a tool
//    window reads back.  A GET with no answer STALLs, exactly as firmware
//    without the feature would, and is logged once - that list is the gap
//    list for the next pass (see `unansweredRequests`).
//  * Meters move: REQ_GET_STATUS synthesises plausible programme levels on
//    the active inputs and the enabled, unmuted outputs.
//  * The extension channel (REQ_EXTENSION 0x00) of the bofr firmware fork,
//    unless built with `extensions: false` (then 0x00 STALLs, as on stock
//    firmware): EXT_LIST lists the crossfeed pair map and the core-voltage
//    status; the pair map lives in the image at bulk offset 44 and a valid
//    write notifies there, an invalid one is ignored, as on the firmware; the
//    core-voltage status is a fixed demo story (raised once from the 1.15 V
//    build default after a failed 1.15 V trial).  Core-voltage writes are
//    ignored.
//
//  Fixtures come from WeebLabs/DSPi-Link `fixtures/device/` at 05949b8 (see
//  dspi-ios/fixtures/README.md for provenance and checksums).
//

import Foundation
import Combine
import os

final class FakeTransport: DeviceTransport {

    // MARK: - Demo device identity

    /// The one device this transport offers.
    static let demoDevice = DSPiDevice(serial: "DEMO-RP2350-0001", locationID: 0,
                                       hub: nil, remoteName: "Demo (no device)")

    /// Whether the app should connect to the demo device by itself at launch:
    /// always in the Simulator (which has no other way to reach a DSPi), and
    /// on a device only when launched with `-DemoMode YES`.  `-DemoMode NO`
    /// turns it off in the Simulator too.
    static var autoSelectAtLaunch: Bool {
        if let explicit = UserDefaults.standard.object(forKey: "DemoMode") as? Bool { return explicit }
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: - DeviceTransport state

    let session: LinkSessionID = 1
    private(set) var generation: UInt64 = 0

    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let devicesSubject = CurrentValueSubject<[DSPiDevice], Never>([FakeTransport.demoDevice])
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

    // MARK: - Simulated device state (guarded by `lock`)

    private let lock = NSLock()
    private let platformReply: Data
    private let factoryImage: Data
    private var image: Data
    private var presets: [Data?] = Array(repeating: nil, count: 10)
    private var presetNames: [String] = Array(repeating: "", count: 10)
    private var activePreset = 0
    private var startupMode: UInt8 = 1       // last active
    private var defaultSlot: UInt8 = 0
    private var echo: [RequestKey: Data] = [:]
    private var unanswered: Set<RequestKey> = []
    private var notifySeq: UInt8 = 0
    private let startTime = Date()
    /// Answer the extension channel (the bofr firmware fork) or STALL it.
    let extensionsEnabled: Bool

    private struct RequestKey: Hashable, CustomStringConvertible {
        let request: UInt8
        let value: UInt16
        let index: UInt16
        var description: String { String(format: "0x%02X wValue=%u wIndex=%u", request, value, index) }
    }

    private static let log = Logger(subsystem: "WeebLabs.DSPi-Console", category: "FakeTransport")

    /// - Parameters:
    ///   - autoSelect: connect to the demo device straight away.
    ///   - extensions: answer REQ_EXTENSION like the bofr firmware fork;
    ///     false STALLs it like stock firmware.
    init(autoSelect: Bool = true, bundle: Bundle = .main, extensions: Bool = true) {
        extensionsEnabled = extensions
        platformReply = FakeTransport.fixture("platform", bundle: bundle) ?? Data([1, 1, 0x16, 9, 1, 6, 5])
        let captured: Data
        if let bulk = FakeTransport.fixture("bulk_v32", bundle: bundle),
           bulk.count == Int(BULK_PARAMS_SIZE), Int(bulk[0]) == WIRE_FORMAT_VERSION {
            captured = bulk
        } else {
            // Without the fixture the console would see an incompatible
            // device; keep the header right so the failure is obvious in the
            // log rather than a reconnect loop.
            FakeTransport.log.error("bulk_v32.bin missing or wrong version; demo device has no state")
            var blank = Data(count: Int(BULK_PARAMS_SIZE))
            blank[0] = UInt8(WIRE_FORMAT_VERSION)
            captured = blank
        }
        factoryImage = captured
        // Slot 1 holds the captured state, as a unit fresh from setup would.
        // Slot 2 is the same state with some EQ, so the demo has curves to
        // show and preset switching has something to switch between.
        var slots: [Data?] = Array(repeating: nil, count: 10)
        slots[0] = captured
        slots[1] = FakeTransport.withDemoEQ(captured)
        // `-DemoPreset 2` starts on slot 2 (for screenshots and UI tests).
        let requested = max(0, min(9, UserDefaults.standard.integer(forKey: "DemoPreset") - 1))
        let startSlot = slots[requested] == nil ? 0 : requested
        image = slots[startSlot] ?? captured
        presets = slots
        // `-DemoPairMap k340` starts with the K340's crossfeed pair map and
        // both pairs crossfed (screenshots of the pair editor).
        if extensions, UserDefaults.standard.string(forKey: "DemoPairMap") == "k340" {
            for i in slots.indices {
                guard var slot = slots[i] else { continue }
                CrossfeedPairMap.oneDACPerEar.encode(into: &slot)
                slot[BULK_CROSSFEED_OFFSET + 3] = CrossfeedPairMap.oneDACPerEarPairMask
                slots[i] = slot
            }
            image = slots[startSlot] ?? image
            presets = slots
        }
        presetNames[0] = "Captured"
        presetNames[1] = "Demo EQ"
        activePreset = startSlot

        if autoSelect {
            DispatchQueue.main.async { [weak self] in self?.selectDevice(FakeTransport.demoDevice) }
        }
    }

    /// The captured image with a gentle house curve on the two USB inputs and
    /// a little correction on the first two outputs.
    private static func withDemoEQ(_ base: Data) -> Data {
        var image = base
        let numIn = Int(image[4])
        // (channel, band, FilterType raw value, freq, q, gain)
        let bands: [(Int, Int, UInt8, Float, Float, Float)] = [
            (0, 0, 2, 80, 0.7, 4.0), (0, 1, 1, 250, 1.2, -2.5), (0, 2, 1, 3150, 2.0, 1.5), (0, 3, 3, 10_000, 0.7, -2.0),
            (1, 0, 2, 80, 0.7, 4.0), (1, 1, 1, 250, 1.2, -2.5), (1, 2, 1, 3150, 2.0, 1.5), (1, 3, 3, 10_000, 0.7, -2.0),
            (numIn, 0, 1, 45, 4.0, -6.0), (numIn, 1, 1, 1_800, 3.0, -3.0),
            (numIn + 1, 0, 1, 52, 4.0, -5.0), (numIn + 1, 1, 1, 2_200, 3.0, -2.5),
        ]
        for (ch, band, type, freq, q, gain) in bands where ch < WIRE_MAX_CHANNELS {
            let base = BULK_EQ_OFFSET + (ch * 12 + band) * WIRE_BAND_PARAMS_SIZE
            var rec = Data([type, 0, 0, 0])
            for value in [freq, q, gain] { withUnsafeBytes(of: value) { rec.append(contentsOf: $0) } }
            image.replaceSubrange(base..<(base + WIRE_BAND_PARAMS_SIZE), with: rec)
        }
        return image
    }

    private static func fixture(_ name: String, bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "bin") else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Connection

    func selectDevice(_ device: DSPiDevice) {
        guard device == FakeTransport.demoDevice else { return }
        lock.lock(); generation &+= 1; lock.unlock()
        selectedSubject.send(device)
        errorSubject.send(nil)
        connectedSubject.send(true)
    }

    func reconnect() {
        guard let device = selectedDevice else { return }
        connectedSubject.send(false)
        selectDevice(device)
    }

    func disconnect() {
        lock.lock(); generation &+= 1; lock.unlock()
        connectedSubject.send(false)
        selectedSubject.send(nil)
    }

    func markDisconnected() {
        connectedSubject.send(false)
    }

    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        fanout.add(handler)
    }

    /// GETs that STALLed because the fake has no model for them, for tests
    /// and the log.
    var unansweredRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return unanswered.map(\.description).sorted()
    }

    // MARK: - SET (host to device)

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        guard isConnected else { return }
        let payload = Data(data)  // re-base indices at 0
        var changes: [(offset: Int, bytes: Data)] = []

        lock.lock()
        switch request {
        case REQ_SET_EQ_PARAM where payload.count >= 16:
            // [ch, band, type, bypass, freq f32, q f32, gain f32 (, qp u16)]
            let ch = Int(payload[0]), band = Int(payload[1])
            if ch < WIRE_MAX_CHANNELS {
                if band < 12 {
                    var rec = Data(count: WIRE_BAND_PARAMS_SIZE)
                    rec[0] = payload[2]; rec[1] = payload[3]
                    if payload.count >= 18 { rec[2] = payload[16]; rec[3] = payload[17] }
                    rec.replaceSubrange(4..<16, with: payload[4..<16])
                    changes.append((BULK_EQ_OFFSET + (ch * 12 + band) * WIRE_BAND_PARAMS_SIZE, rec))
                } else if (20..<24).contains(band) {
                    var rec = Data(count: WIRE_BAND_PARAMS_SIZE)
                    rec[0] = payload[2]; rec[1] = payload[3]
                    rec.replaceSubrange(4..<16, with: payload[4..<16])
                    changes.append((BULK_CROSSOVER_OFFSET + (ch * 4 + band - 20) * WIRE_BAND_PARAMS_SIZE, rec))
                }
            }
        case REQ_SET_BAND_BYPASS where !payload.isEmpty:
            // wValue: channel in the high byte, wire band in the low byte.
            let ch = Int(value >> 8), band = Int(value & 0xFF)
            if ch < WIRE_MAX_CHANNELS && band < 12 {
                changes.append((BULK_EQ_OFFSET + (ch * 12 + band) * WIRE_BAND_PARAMS_SIZE + 1, Data([payload[0] != 0 ? 1 : 0])))
            } else if ch < WIRE_MAX_CHANNELS && (20..<24).contains(band) {
                changes.append((BULK_CROSSOVER_OFFSET + (ch * 4 + band - 20) * WIRE_BAND_PARAMS_SIZE + 1, Data([payload[0] != 0 ? 1 : 0])))
            }
        case REQ_SET_PREAMP where payload.count >= 4:
            changes.append((BULK_GLOBAL_OFFSET, payload.prefix(4)))
        case REQ_SET_PREAMP_CH where payload.count >= 4 && value < 8:
            changes.append((BULK_PREAMP_OFFSET + Int(value) * 4, payload.prefix(4)))
        case REQ_SET_BYPASS where !payload.isEmpty:
            changes.append((BULK_GLOBAL_OFFSET + 4, payload.prefix(1)))
        case REQ_SET_LOUDNESS where !payload.isEmpty:
            changes.append((BULK_GLOBAL_OFFSET + 5, payload.prefix(1)))
        case REQ_SET_CROSSFEED where !payload.isEmpty:
            changes.append((BULK_CROSSFEED_OFFSET, payload.prefix(1)))
        case REQ_SET_DELAY where payload.count >= 4 && Int(value) < WIRE_MAX_CHANNELS:
            changes.append((BULK_DELAYS_OFFSET + Int(value) * 4, payload.prefix(4)))
        case REQ_SET_MATRIX_ROUTE where payload.count >= 8:
            // [input, output, enabled, invert, gain f32]
            let input = Int(payload[0]), output = Int(payload[1])
            if input < 8 && output < 9 {
                var rec = Data(count: WIRE_CROSSPOINT_SIZE)
                rec[0] = payload[2]; rec[1] = payload[3]
                rec.replaceSubrange(4..<8, with: payload[4..<8])
                changes.append((BULK_CROSSPOINT_OFFSET + (input * 9 + output) * WIRE_CROSSPOINT_SIZE, rec))
            }
        case REQ_SET_OUTPUT_ENABLE where !payload.isEmpty && value < 9:
            changes.append((BULK_OUTPUTS_OFFSET + Int(value) * 12, payload.prefix(1)))
        case REQ_SET_OUTPUT_MUTE where !payload.isEmpty && value < 9:
            changes.append((BULK_OUTPUTS_OFFSET + Int(value) * 12 + 1, payload.prefix(1)))
        case REQ_SET_OUTPUT_GAIN where payload.count >= 4 && value < 9:
            changes.append((BULK_OUTPUTS_OFFSET + Int(value) * 12 + 4, payload.prefix(4)))
        case REQ_SET_OUTPUT_DELAY where payload.count >= 4 && value < 9:
            changes.append((BULK_OUTPUTS_OFFSET + Int(value) * 12 + 8, payload.prefix(4)))
        case REQ_SET_CHANNEL_NAME where Int(value) < WIRE_MAX_CHANNELS:
            var name = Data(payload.prefix(31))
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            changes.append((BULK_CHANNEL_NAMES_OFFSET + Int(value) * 32, name))
        case REQ_SET_INPUT_SOURCE where !payload.isEmpty:
            changes.append((BULK_INPUT_CONFIG_OFFSET, payload.prefix(1)))
        case REQ_SET_LG_SOUND_SYNC_ENABLE where !payload.isEmpty:
            changes.append((BULK_LG_OFFSET, payload.prefix(1)))
        case REQ_SET_MASTER_VOLUME where payload.count >= 4:
            changes.append((BULK_MASTER_VOLUME_OFFSET, payload.prefix(4)))
        case REQ_SET_USER_VOLUME where payload.count >= 4:
            changes.append((BULK_USER_VOLUME_OFFSET, payload.prefix(4)))
        case REQ_SET_ALL_PARAMS where payload.count == Int(BULK_PARAMS_SIZE) && Int(payload[0]) == WIRE_FORMAT_VERSION:
            image = payload
        case REQ_PRESET_SET_NAME where value < 10:
            let bytes = payload.prefix { $0 != 0 }
            presetNames[Int(value)] = String(decoding: bytes, as: UTF8.self)
        case REQ_PRESET_SET_STARTUP where payload.count >= 2:
            startupMode = payload[0]
            defaultSlot = payload[1]
        case REQ_EXTENSION where extensionsEnabled && value == EXT_CROSSFEED_PAIR_MAP
                                 && payload.count == CrossfeedPairMap.byteCount:
            // The firmware ignores an invalid map and stores a valid one
            // normalized.
            let map = CrossfeedPairMap(payload)
            if map.isValid(pairCount: fakePairCount) {
                changes.append((BULK_CROSSFEED_PAIR_MAP_OFFSET, map.normalized.data))
            }
        default:
            break
        }
        for change in changes {
            image.replaceSubrange(change.offset..<(change.offset + change.bytes.count), with: change.bytes)
        }
        // Whatever the SET, its GET twin reads it back.
        if let get = FakeTransport.getTwin[request] {
            echo[RequestKey(request: get, value: value, index: index)] = payload
        }
        lock.unlock()

        for change in changes { notifyParamChanged(offset: change.offset, bytes: change.bytes) }
    }

    /// PARAM_CHANGED as the firmware sends it for a host write:
    /// [ver=2, evt=0x02, flags, seq, off u16, size u16, src=HOST_SET, 0, 0, 0, value...]
    /// Attributed to this transport's own session, so the view model treats
    /// it as the echo of its own write; the Interrupt Monitor shows it.
    private func notifyParamChanged(offset: Int, bytes: Data) {
        lock.lock(); notifySeq &+= 1; let seq = notifySeq; lock.unlock()
        var packet = Data([0x02, 0x02, 0x00, seq,
                           UInt8(offset & 0xFF), UInt8(offset >> 8),
                           UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8),
                           0x01, 0, 0, 0])
        packet.append(bytes.prefix(52))
        fanout.publish(LinkNotification(packet: packet, origin: session, receivedAt: Date()))
    }

    // MARK: - GET (device to host)

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        guard isConnected else { return .failure(.noDevice) }
        lock.lock(); defer { lock.unlock() }

        let reply: Data?
        switch request {
        case REQ_GET_PLATFORM:
            reply = platformReply
        case REQ_GET_SERIAL:
            reply = Data(FakeTransport.demoDevice.serial.utf8)
        case REQ_GET_ALL_PARAMS:
            reply = image
        case REQ_GET_STATUS:
            reply = status(value: value, length: Int(length))
        case REQ_GET_INPUT_SOURCE:
            reply = image.subdata(in: BULK_INPUT_CONFIG_OFFSET..<(BULK_INPUT_CONFIG_OFFSET + 1))
        case REQ_GET_USER_VOLUME:
            reply = image.subdata(in: BULK_USER_VOLUME_OFFSET..<(BULK_USER_VOLUME_OFFSET + 4))
        case REQ_GET_MASTER_VOLUME:
            reply = image.subdata(in: BULK_MASTER_VOLUME_OFFSET..<(BULK_MASTER_VOLUME_OFFSET + 4))
        case REQ_GET_LG_SOUND_SYNC_ENABLE:
            reply = image.subdata(in: BULK_LG_OFFSET..<(BULK_LG_OFFSET + 1))
        case REQ_GET_CORE1_MODE, REQ_GET_CORE1_CONFLICT:
            reply = echo[RequestKey(request: request, value: value, index: index)] ?? Data([0])
        case REQ_CLEAR_CLIPS:
            reply = Data([0, 0])
        case REQ_EXTENSION where extensionsEnabled:
            reply = extensionReply(value)

        // Presets and flash.
        case REQ_PRESET_GET_DIR:
            var occupied: UInt16 = 0
            for (slot, saved) in presets.enumerated() where saved != nil { occupied |= 1 << UInt16(slot) }
            reply = Data([UInt8(occupied & 0xFF), UInt8(occupied >> 8), startupMode, defaultSlot,
                          UInt8(activePreset), UInt8(OUTPUT_CONFIG_MODE_INDEPENDENT),
                          UInt8(MASTER_VOLUME_MODE_INDEPENDENT)])
        case REQ_PRESET_GET_NAME where value < 10:
            var name = Data(presetNames[Int(value)].utf8.prefix(31))
            name.append(contentsOf: [UInt8](repeating: 0, count: 32 - name.count))
            reply = name
        case REQ_PRESET_GET_ACTIVE:
            reply = Data([UInt8(activePreset)])
        case REQ_PRESET_GET_STARTUP:
            reply = Data([startupMode, defaultSlot, UInt8(activePreset)])
        case REQ_PRESET_SAVE where value < 10:
            presets[Int(value)] = image
            activePreset = Int(value)
            reply = Data([PRESET_OK])
        case REQ_PRESET_LOAD where value < 10:
            image = presets[Int(value)] ?? factoryImage
            activePreset = Int(value)
            reply = Data([PRESET_OK])
        case REQ_PRESET_DELETE where value < 10:
            presets[Int(value)] = nil
            presetNames[Int(value)] = ""
            reply = Data([PRESET_OK])
        case REQ_SAVE_PARAMS:
            presets[activePreset] = image
            reply = Data([FLASH_OK])
        case REQ_FACTORY_RESET:
            image = factoryImage
            reply = Data([FLASH_OK])

        default:
            reply = echo[RequestKey(request: request, value: value, index: index)]
        }

        guard var data = reply else {
            let key = RequestKey(request: request, value: value, index: index)
            if unanswered.insert(key).inserted {
                FakeTransport.log.info("unanswered GET \(key.description, privacy: .public) length=\(length)")
            }
            return .failure(.error)
        }
        // A control transfer returns at most wLength bytes.
        if data.count > Int(length) { data = data.prefix(Int(length)) }
        return .success(Data(data))
    }

    // MARK: - Extension channel

    /// Crossfeed pairs of the image's platform: every output but the PDM sub,
    /// two per pair (4 on RP2350, 2 on RP2040).
    private var fakePairCount: Int {
        min(max((Int(image[3]) - 1) / 2, 1), CrossfeedPairMap.byteCount)
    }

    /// IN replies of the sub-commands the fork has; nil (STALL) for others.
    private func extensionReply(_ value: UInt16) -> Data? {
        switch value {
        case EXT_LIST:
            return Data([UInt8(EXT_CROSSFEED_PAIR_MAP & 0xFF), UInt8(EXT_CROSSFEED_PAIR_MAP >> 8),
                         UInt8(EXT_CORE_VREG & 0xFF), UInt8(EXT_CORE_VREG >> 8)])
        case EXT_CROSSFEED_PAIR_MAP:
            return CrossfeedPairMap(bulk: image).data
        case EXT_CORE_VREG:
            // Live and stored 1.20 V, raised by the firmware from the 1.15 V
            // build default after a 1.15 V trial hung 12 min 34 s in.
            var reply = Data([0x0D, 0x0D, 0x0C, CoreVregStatus.flagAutoRaised, 0, 0, 0, 0x0C])
            for v in [UInt32(754), UInt32(Date().timeIntervalSince(startTime)) + 3_725] {
                withUnsafeBytes(of: v.littleEndian) { reply.append(contentsOf: $0) }
            }
            return reply
        default:
            return nil
        }
    }

    // MARK: - Meters

    /// REQ_GET_STATUS.  wValue 9 is the combined meter block the console polls
    /// every 60 ms: peaks u16[numCh], cpu0, cpu1, clip flags u32, active input
    /// count.  wValue 15 is the sample rate.  Anything else reads as zeros.
    private func status(value: UInt16, length: Int) -> Data {
        switch value {
        case 15:
            var rate: UInt32 = 48_000
            return Data(bytes: &rate, count: 4)
        case 9:
            let numChannels = max(0, (length - 7) / 2)
            let numIn = Int(image[4])
            let t = Date().timeIntervalSince(startTime)
            var out = Data(count: length)
            // Programme on the two USB inputs: a slow swell with a little
            // flutter, the right channel a beat behind the left.
            var inputLevels: [Double] = []
            for ch in 0..<2 {
                let phase = Double(ch) * 0.9
                let swell = 0.55 + 0.25 * sin(t * 0.7 + phase)
                let flutter = 0.12 * sin(t * 7.3 + phase * 3) + 0.06 * sin(t * 13.1 + phase)
                inputLevels.append(max(0.02, min(0.97, swell + flutter)))
            }
            for ch in 0..<numChannels {
                var level: Double = 0
                if ch < numIn {
                    level = ch < inputLevels.count ? inputLevels[ch] : 0
                } else {
                    let output = ch - numIn
                    let base = BULK_OUTPUTS_OFFSET + output * 12
                    if output < 9, image[base] != 0, image[base + 1] == 0 {
                        // Each output follows the inputs at its own level.
                        let source = inputLevels[output % 2]
                        level = source * (0.75 + 0.2 * sin(Double(output) * 1.7))
                    }
                }
                let raw = UInt16(max(0, min(32767, level * 32767)))
                out[ch * 2] = UInt8(raw & 0xFF)
                out[ch * 2 + 1] = UInt8(raw >> 8)
            }
            let off = numChannels * 2
            if length >= off + 7 {
                out[off] = UInt8(18 + 4 * sin(t * 0.5))       // core 0 load, %
                out[off + 1] = UInt8(31 + 3 * sin(t * 0.37))  // core 1 load, %
                // clip flags stay 0; active input count follows the USB format
                out[off + 6] = 2
            }
            return out
        default:
            return Data(count: length)
        }
    }

    // MARK: - SET -> GET pairs for the echo store

    /// The GET that reads back what each SET writes, for requests the fake
    /// models only as "remember the last value".  Addressing (wValue/wIndex)
    /// is assumed to match between the two, which holds for these.
    private static let getTwin: [UInt8: UInt8] = {
        let pairs: [(UInt8, UInt8)] = [
            (REQ_SET_PREAMP, REQ_GET_PREAMP), (REQ_SET_BYPASS, REQ_GET_BYPASS),
            (REQ_SET_DELAY, REQ_GET_DELAY),
            (REQ_SET_INPUT_SOURCE_NAME, REQ_GET_INPUT_SOURCE_NAME), (REQ_SET_DEVICE_NAME, REQ_GET_DEVICE_NAME),
            (REQ_SET_LOUDNESS, REQ_GET_LOUDNESS), (REQ_SET_LOUDNESS_REF, REQ_GET_LOUDNESS_REF),
            (REQ_SET_LOUDNESS_INTENSITY, REQ_GET_LOUDNESS_INTENSITY), (REQ_SET_LOUDNESS_MASK, REQ_GET_LOUDNESS_MASK),
            (REQ_SET_CROSSFEED, REQ_GET_CROSSFEED), (REQ_SET_CROSSFEED_PRESET, REQ_GET_CROSSFEED_PRESET),
            (REQ_SET_CROSSFEED_FREQ, REQ_GET_CROSSFEED_FREQ), (REQ_SET_CROSSFEED_FEED, REQ_GET_CROSSFEED_FEED),
            (REQ_SET_CROSSFEED_ITD, REQ_GET_CROSSFEED_ITD), (REQ_SET_CROSSFEED_OUTPUTS, REQ_GET_CROSSFEED_OUTPUTS),
            (REQ_SET_PSYBASS, REQ_GET_PSYBASS), (REQ_SET_PSYBASS_CUTOFF, REQ_GET_PSYBASS_CUTOFF),
            (REQ_SET_PSYBASS_HARMONICS, REQ_GET_PSYBASS_HARMONICS), (REQ_SET_PSYBASS_DRIVE, REQ_GET_PSYBASS_DRIVE),
            (REQ_SET_PSYBASS_CHARACTER, REQ_GET_PSYBASS_CHARACTER), (REQ_SET_PSYBASS_ORIGINAL, REQ_GET_PSYBASS_ORIGINAL),
            (REQ_SET_PSYBASS_MASK, REQ_GET_PSYBASS_MASK),
            (REQ_SET_SUBHARM, REQ_GET_SUBHARM), (REQ_SET_SUBHARM_LOW, REQ_GET_SUBHARM_LOW),
            (REQ_SET_SUBHARM_HIGH, REQ_GET_SUBHARM_HIGH), (REQ_SET_SUBHARM_BOOST, REQ_GET_SUBHARM_BOOST),
            (REQ_SET_SUBHARM_MASK, REQ_GET_SUBHARM_MASK), (REQ_SET_SUBHARM_TOP, REQ_GET_SUBHARM_TOP),
            (REQ_SET_SUBHARM_SOLO, REQ_GET_SUBHARM_SOLO), (REQ_SET_SUBHARM_LINK, REQ_GET_SUBHARM_LINK),
            (REQ_SET_SUBHARM_DEPTH, REQ_GET_SUBHARM_DEPTH), (REQ_SET_SUBHARM_HOLD, REQ_GET_SUBHARM_HOLD),
            (REQ_SET_SUBHARM_CEILING, REQ_GET_SUBHARM_CEILING),
            (REQ_SET_TUBE_PARAM, REQ_GET_TUBE_PARAM),
            (REQ_SET_MATRIX_ROUTE, REQ_GET_MATRIX_ROUTE),
            (REQ_SET_OUTPUT_ENABLE, REQ_GET_OUTPUT_ENABLE), (REQ_SET_OUTPUT_GAIN, REQ_GET_OUTPUT_GAIN),
            (REQ_SET_OUTPUT_MUTE, REQ_GET_OUTPUT_MUTE), (REQ_SET_OUTPUT_DELAY, REQ_GET_OUTPUT_DELAY),
            (REQ_SET_OUTPUT_PIN, REQ_GET_OUTPUT_PIN), (REQ_SET_OUTPUT_TYPE, REQ_GET_OUTPUT_TYPE),
            (REQ_SET_MCK_ENABLE, REQ_GET_MCK_ENABLE), (REQ_SET_MCK_PIN, REQ_GET_MCK_PIN),
            (REQ_SET_MCK_MULTIPLIER, REQ_GET_MCK_MULTIPLIER),
            (REQ_SET_LEVELLER, REQ_GET_LEVELLER), (REQ_SET_LEVELLER_AMOUNT, REQ_GET_LEVELLER_AMOUNT),
            (REQ_SET_LEVELLER_SPEED, REQ_GET_LEVELLER_SPEED), (REQ_SET_LEVELLER_MAXGAIN, REQ_GET_LEVELLER_MAXGAIN),
            (REQ_SET_LEVELLER_LOOKAHEAD, REQ_GET_LEVELLER_LOOKAHEAD), (REQ_SET_LEVELLER_GATE, REQ_GET_LEVELLER_GATE),
            (REQ_SET_LEVELLER_MASKS, REQ_GET_LEVELLER_MASKS),
            (REQ_SET_PREAMP_CH, REQ_GET_PREAMP_CH), (REQ_SET_BAND_BYPASS, REQ_GET_BAND_BYPASS),
            (REQ_SET_MASTER_VOLUME_MODE, REQ_GET_MASTER_VOLUME_MODE),
            (REQ_SET_INPUT_SOURCE, REQ_GET_INPUT_SOURCE),
            (REQ_SET_DAC_HW_MUTE_CONFIG, REQ_GET_DAC_HW_MUTE_CONFIG),
            (REQ_SET_LG_SOUND_SYNC_ENABLE, REQ_GET_LG_SOUND_SYNC_ENABLE),
            (REQ_SET_OUTPUT_CONFIG_MODE, REQ_GET_OUTPUT_CONFIG_MODE),
        ]
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }()
}
