import XCTest
import Combine
@testable import DSPi_Console

/// The extension channel's wire formats (ExtensionChannel.swift): the EXT_LIST
/// reply, the crossfeed pair map with the firmware's validation
/// (crossfeed_map.h) and its bulk position, and CoreVregStatus.
final class ExtensionChannelWireTests: XCTestCase {

    // MARK: - EXT_LIST

    func testListReplyDecodesLittleEndianIDs() {
        let ext = DeviceExtensions(listReply: Data([0x01, 0x00, 0x02, 0x00]))
        XCTAssertEqual(ext.ids, [EXT_CROSSFEED_PAIR_MAP, EXT_CORE_VREG])
        XCTAssertTrue(ext.crossfeedPairMap)
        XCTAssertTrue(ext.coreVreg)
        XCTAssertEqual(DeviceExtensions(listReply: Data([0x34, 0x12])).ids, [0x1234])
    }

    func testListReplyIgnoresAnOddByteAndIDZero() {
        XCTAssertEqual(DeviceExtensions(listReply: Data([0x00, 0x00, 0x02, 0x00, 0x01])).ids, [EXT_CORE_VREG])
        XCTAssertEqual(DeviceExtensions(listReply: Data()).ids, [])
        XCTAssertFalse(DeviceExtensions.none.crossfeedPairMap)
    }

    func testRequestConstants() {
        XCTAssertEqual(REQ_EXTENSION, 0x00)
        XCTAssertEqual(EXT_LIST, 0x0000)
        XCTAssertEqual(EXT_CROSSFEED_PAIR_MAP, 0x0001)
        XCTAssertEqual(EXT_CORE_VREG, 0x0002)
        XCTAssertEqual(EXT_WINDEX, 2)
    }

    // MARK: - Pair map encoding

    func testEncodingIsRightHighLeftLow() {
        XCTAssertEqual(CrossfeedPairMap.encode(left: 3, right: 1), 0x13)
        XCTAssertEqual(CrossfeedPairMap.encode(left: 2, right: 0), 0x02)
        XCTAssertEqual(CrossfeedPairMap.oneDACPerEar.bytes, [0x02, 0x13, 0x00, 0x00])
        let k340 = CrossfeedPairMap.oneDACPerEar
        XCTAssertTrue(k340.pair(0) == (2, 0))
        XCTAssertTrue(k340.pair(1) == (3, 1))
        XCTAssertTrue(k340.pair(2) == (4, 5), "0 decodes as the default pair")
        XCTAssertTrue(k340.pair(3) == (6, 7))
    }

    func testFromPairsWritesDefaultPairsAsZero() {
        let map = CrossfeedPairMap.from(pairs: [(2, 0), (3, 1), (4, 5)])
        XCTAssertEqual(map.bytes, [0x02, 0x13, 0x00, 0x00])
        XCTAssertEqual(CrossfeedPairMap.from(pairs: [(0, 1), (2, 3)]), .default)
    }

    /// The editor's check: (0, 0) encodes as 0x00, the default pair, so the
    /// pairs themselves must be checked before encoding.
    func testValidatedPairs() {
        XCTAssertEqual(CrossfeedPairMap.validated(pairs: [(2, 0), (3, 1)], pairCount: 2), .oneDACPerEar)
        XCTAssertEqual(CrossfeedPairMap.validated(pairs: [(0, 1), (2, 3)], pairCount: 2), .default)
        XCTAssertNil(CrossfeedPairMap.validated(pairs: [(0, 0), (2, 3)], pairCount: 2), "output 1 twice")
        XCTAssertNil(CrossfeedPairMap.validated(pairs: [(1, 1), (2, 3)], pairCount: 2))
        XCTAssertNil(CrossfeedPairMap.validated(pairs: [(0, 2), (2, 3)], pairCount: 2), "output 3 in two pairs")
        XCTAssertNil(CrossfeedPairMap.validated(pairs: [(0, 1)], pairCount: 2), "one pair missing")
        XCTAssertNil(CrossfeedPairMap.validated(pairs: [(0, 4), (2, 3)], pairCount: 2), "the RP2040 PDM sub")
        XCTAssertNil(CrossfeedPairMap.validated(pairs: [(0, 17), (2, 3)], pairCount: 2), "beyond a nibble")
    }

    func testShortAndLongByteArraysAreFittedToFourBytes() {
        XCTAssertEqual(CrossfeedPairMap(bytes: [0x02]).bytes, [0x02, 0, 0, 0])
        XCTAssertEqual(CrossfeedPairMap(bytes: [1, 2, 3, 4, 5]).bytes, [1, 2, 3, 4])
    }

    // MARK: - Validation (the firmware's test cases)

    func testValidationMatchesTheFirmware() {
        let k340 = CrossfeedPairMap.oneDACPerEar
        XCTAssertTrue(CrossfeedPairMap.default.isValid(pairCount: 4))
        XCTAssertTrue(CrossfeedPairMap.default.isValid(pairCount: 2))
        XCTAssertTrue(k340.isValid(pairCount: 4))
        XCTAssertTrue(k340.isValid(pairCount: 2))
        XCTAssertFalse(CrossfeedPairMap(bytes: [0x11, 0, 0, 0]).isValid(pairCount: 4), "same output twice")
        XCTAssertFalse(CrossfeedPairMap(bytes: [0x02, 0, 0, 0]).isValid(pairCount: 4), "output 2 shared with default pair 1")
        XCTAssertFalse(CrossfeedPairMap(bytes: [0x40, 0, 0, 0]).isValid(pairCount: 2), "RP2040 output 4 is the PDM sub")
        XCTAssertFalse(CrossfeedPairMap(bytes: [0x80, 0, 0, 0]).isValid(pairCount: 4), "RP2350 output 8 is the PDM sub")
        XCTAssertFalse(CrossfeedPairMap(bytes: [0, 0, 0x54, 0]).isValid(pairCount: 2), "pairs beyond the platform must be 0")
        XCTAssertTrue(CrossfeedPairMap(bytes: [0x76, 0x54, 0x32, 0x10]).isValid(pairCount: 4))
        XCTAssertFalse(CrossfeedPairMap.default.isValid(pairCount: 0))
        XCTAssertFalse(CrossfeedPairMap.default.isValid(pairCount: 5))
    }

    /// Every two-pair map: 24 pairings of four outputs, plus 5 duplicate
    /// encodings of a default pair (0x10 for pair 0, 0x32 for pair 1).
    func testExhaustiveTwoPairCount() {
        var valid = 0
        var pairings = Set<[Int]>()
        for a in 0...255 {
            for b in 0...255 {
                let map = CrossfeedPairMap(bytes: [UInt8(a), UInt8(b), 0, 0])
                guard map.isValid(pairCount: 2) else { continue }
                valid += 1
                let outputs = [map.pair(0).left, map.pair(0).right, map.pair(1).left, map.pair(1).right]
                pairings.insert(outputs)
                // A valid map is a permutation of outputs 0...3.
                XCTAssertEqual(Set(outputs), [0, 1, 2, 3])
            }
        }
        XCTAssertEqual(valid, 29)
        XCTAssertEqual(pairings.count, 24)
    }

    /// Every way to deal the eight RP2350 stereo outputs into four ordered
    /// pairs is valid, normalizes to a distinct map, and the RP2040 rules
    /// reject all of those that touch outputs 4-7.
    func testEveryFourPairPermutationIsValid() {
        var maps = Set<CrossfeedPairMap>()
        func permute(_ rest: [Int], _ chosen: [Int]) {
            if rest.isEmpty {
                let pairs = (0..<4).map { (left: chosen[2 * $0], right: chosen[2 * $0 + 1]) }
                let map = CrossfeedPairMap.from(pairs: pairs)
                XCTAssertTrue(map.isValid(pairCount: 4))
                XCTAssertEqual(map.normalized, map)
                maps.insert(map)
                return
            }
            for (i, o) in rest.enumerated() {
                var r = rest; r.remove(at: i)
                permute(r, chosen + [o])
            }
        }
        permute(Array(0..<8), [])
        XCTAssertEqual(maps.count, 40_320)
    }

    // MARK: - Normalization

    func testNormalization() {
        XCTAssertEqual(CrossfeedPairMap(bytes: [0x10, 0x32, 0x54, 0x76]).normalized, .default)
        XCTAssertEqual(CrossfeedPairMap(bytes: [0x10, 0x13, 0x02, 0x76]).normalized.bytes, [0, 0x13, 0x02, 0])
        XCTAssertTrue(CrossfeedPairMap(bytes: [0x10, 0x32, 0, 0]).isDefault)
        XCTAssertTrue(CrossfeedPairMap(bytes: [0x02, 0x13, 0x54, 0]).samePairing(as: .oneDACPerEar))
    }

    func testLoadedFallsBackToDefaultWhenInvalid() {
        XCTAssertEqual(CrossfeedPairMap(bytes: [0x02, 0x13, 0x54, 0]).loaded(pairCount: 4), .oneDACPerEar)
        XCTAssertEqual(CrossfeedPairMap(bytes: [0x76, 0x54, 0x32, 0x10]).loaded(pairCount: 2), .default)
        XCTAssertEqual(CrossfeedPairMap(bytes: [0x11, 0, 0, 0]).loaded(pairCount: 4), .default)
    }

    // MARK: - Bulk image

    func testBulkOffsetIsTheCrossfeedSectionsReserved2() {
        XCTAssertEqual(BULK_CROSSFEED_PAIR_MAP_OFFSET, 44)
        XCTAssertEqual(BULK_CROSSFEED_PAIR_MAP_OFFSET, BULK_CROSSFEED_OFFSET + 12)
    }

    func testBulkRoundTrip() {
        var bulk = Data(count: Int(BULK_PARAMS_SIZE))
        XCTAssertEqual(CrossfeedPairMap(bulk: bulk), .default, "zero (stock firmware) is the default")
        CrossfeedPairMap.oneDACPerEar.encode(into: &bulk)
        XCTAssertEqual(Array(bulk[44..<48]), [0x02, 0x13, 0x00, 0x00])
        XCTAssertEqual(Array(bulk[40..<44]), [0, 0, 0, 0], "feed level untouched")
        XCTAssertEqual(bulk[48], 0)
        XCTAssertEqual(CrossfeedPairMap(bulk: bulk), .oneDACPerEar)
        // A slice with a non-zero start index decodes the same.
        let slice = (Data([0xFF]) + bulk).dropFirst()
        XCTAssertEqual(CrossfeedPairMap(bulk: slice), .oneDACPerEar)
        XCTAssertEqual(CrossfeedPairMap(bulk: Data(count: 10)), .default, "a short image reads as default")
    }

    // MARK: - CoreVregStatus

    func testCoreVregStatusDecodes() throws {
        let raw = Data([0x0D, 0x0E, 0x0C, 0x03, 2, 1, 0x0F, 0x0C,
                        0x10, 0x27, 0x00, 0x00,    // 10000 s
                        0x01, 0x02, 0x03, 0x00])   // 0x030201 s
        let s = try XCTUnwrap(CoreVregStatus(raw))
        XCTAssertEqual(s.liveVreg, 0x0D)
        XCTAssertEqual(s.storedSel, 0x0E)
        XCTAssertEqual(s.defaultVreg, 0x0C)
        XCTAssertTrue(s.autoRaised)
        XCTAssertTrue(s.autoRaiseDisabled)
        XCTAssertEqual(s.hangCount, 2)
        XCTAssertTrue(s.trialActive)
        XCTAssertEqual(s.trialVreg, 0x0F)
        XCTAssertEqual(s.failedTrialVreg, 0x0C)
        XCTAssertTrue(s.hasFailedTrial)
        XCTAssertEqual(s.failedTrialUptimeS, 10_000)
        XCTAssertEqual(s.uptimeS, 0x030201)
        XCTAssertEqual(s.storedVreg, 0x0E)
        XCTAssertNil(CoreVregStatus(raw.prefix(15)), "short reply")
    }

    func testStoredZeroMeansBuildDefault() throws {
        let s = try XCTUnwrap(CoreVregStatus(Data([0x0C, 0, 0x0C, 0] + [UInt8](repeating: 0, count: 12))))
        XCTAssertEqual(s.storedVreg, 0x0C)
        XCTAssertFalse(s.autoRaised)
        XCTAssertFalse(s.hasFailedTrial)
    }

    func testVregCodesInVolts() {
        for platform in ["RP2350", "RP2040"] {
            XCTAssertEqual(VregVoltage.label(0x0C, platform: platform), "1.15 V")
            XCTAssertEqual(VregVoltage.label(0x0D, platform: platform), "1.20 V")
            XCTAssertEqual(VregVoltage.label(0x0E, platform: platform), "1.25 V")
            XCTAssertEqual(VregVoltage.label(0x0F, platform: platform), "1.30 V")
            XCTAssertEqual(VregVoltage.label(0x0B, platform: platform), "1.10 V")
            XCTAssertEqual(VregVoltage.label(0x06, platform: platform), "0.85 V")
        }
        XCTAssertEqual(VregVoltage.label(0x00, platform: "RP2350"), "0.55 V")
        XCTAssertEqual(VregVoltage.label(0x00, platform: "RP2040"), "0.80 V", "RP2040 codes 0-5 all program 0.80 V")
        XCTAssertEqual(VregVoltage.label(0x10, platform: "RP2350"), "1.35 V")
        XCTAssertEqual(VregVoltage.label(0x1F, platform: "RP2350"), "3.30 V")
        XCTAssertEqual(VregVoltage.label(0x10, platform: "RP2040"), "code 0x10")
        XCTAssertEqual(VregVoltage.label(0x20, platform: "RP2350"), "code 0x20")
    }

    func testUptimeFormat() {
        XCTAssertEqual(formatUptime(42), "42 s")
        XCTAssertEqual(formatUptime(754), "12 min 34 s")
        XCTAssertEqual(formatUptime(3_725), "1 h 2 min")
        XCTAssertEqual(formatUptime(90_061), "1 d 1 h")
    }
}

// MARK: - Through the view model

/// The probe, the pair map and the core-voltage status through the real view
/// model, on the demo device (which answers like the bofr firmware), on a
/// demo device that STALLs 0x00 like stock firmware, over USB MIDI, and on a
/// transport that fails the probe in each of the ways a link can.
final class ExtensionChannelViewModelTests: XCTestCase {

    private func fetched(_ vm: DSPViewModel, timeout: TimeInterval = 30) {
        let done = expectation(description: "fetchAll")
        DispatchQueue.global().async {
            vm.fetchAll()
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
    }

    /// Let main-queue publications from background work land.
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func fakeVM(extensions: Bool = true) -> (FakeTransport, DSPViewModel) {
        let fake = FakeTransport(autoSelect: false, extensions: extensions)
        let vm = DSPViewModel(transport: fake)
        fake.selectDevice(FakeTransport.demoDevice)
        return (fake, vm)
    }

    func testProbeFindsTheExtensionsOnTheDemoDevice() throws {
        let (_, vm) = fakeVM()
        fetched(vm)
        XCTAssertEqual(vm.extensionProbe, .supported(DeviceExtensions(ids: [EXT_CROSSFEED_PAIR_MAP, EXT_CORE_VREG])))
        XCTAssertTrue(vm.crossfeedPairMapSupported)
        XCTAssertTrue(vm.coreVregSupported)
        XCTAssertEqual(vm.crossfeed.pairMap, .default)
        let vreg = try XCTUnwrap(vm.coreVregStatus)
        XCTAssertEqual(vreg.liveVreg, 0x0D)
        XCTAssertEqual(vreg.defaultVreg, 0x0C)
        XCTAssertEqual(vm.crossfeedPairCount, 4)
    }

    func testStockFirmwareHasNoExtensions() {
        let (fake, vm) = fakeVM(extensions: false)
        fetched(vm)
        XCTAssertEqual(vm.extensionProbe, .unsupported)
        XCTAssertFalse(vm.crossfeedPairMapSupported)
        XCTAssertFalse(vm.coreVregSupported)
        XCTAssertNil(vm.coreVregStatus)
        XCTAssertFalse(vm.setCrossfeedPairMap(.oneDACPerEar), "never written to firmware without the map")
        settle()
        XCTAssertEqual(CrossfeedPairMap(bulk: fake.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2,
                                                                     length: BULK_PARAMS_SIZE) ?? Data()), .default)
        // Only the one EXT_LIST read reached the device.
        XCTAssertEqual(fake.unansweredRequests.filter { $0.hasPrefix("0x00 ") }, ["0x00 wValue=0 wIndex=2"])
    }

    func testRefreshDoesNotProbeAgainButAReconnectDoes() {
        let fake = FakeTransport(autoSelect: false)
        let counter = CountingTransport(fake)
        let vm = DSPViewModel(transport: counter)
        // The connect path's own fetch probes once.
        fake.selectDevice(FakeTransport.demoDevice)
        XCTAssertTrue(spinUntil(30) { vm.coreVregStatus != nil })
        XCTAssertEqual(counter.extensionGets(EXT_LIST), 1)
        fetched(vm)
        XCTAssertEqual(counter.extensionGets(EXT_LIST), 1, "a refresh reuses the probe")
        fake.reconnect()
        XCTAssertTrue(spinUntil(30) { counter.extensionGets(EXT_LIST) == 2 }, "a new connection probes again")
        XCTAssertTrue(spinUntil(5) { vm.coreVregSupported })
    }

    func testBulkReadCarriesThePairMap() {
        let (fake, vm) = fakeVM()
        fake.sendControlRequest(request: REQ_EXTENSION, value: EXT_CROSSFEED_PAIR_MAP, index: EXT_WINDEX,
                                data: CrossfeedPairMap.oneDACPerEar.data)
        fetched(vm)
        XCTAssertEqual(vm.crossfeed.pairMap, .oneDACPerEar)
    }

    func testSetPairMapFollowsTheDevice() throws {
        let (fake, vm) = fakeVM()
        fetched(vm)
        var packets: [Data] = []
        let token = fake.addNotificationObserver { packets.append($0.packet) }
        defer { token.cancel() }

        XCTAssertTrue(vm.setCrossfeedPairMap(.oneDACPerEar))
        XCTAssertTrue(spinUntil(5) { vm.crossfeed.pairMap == .oneDACPerEar })
        let bulk = try XCTUnwrap(fake.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE))
        XCTAssertEqual(Array(bulk[44..<48]), [0x02, 0x13, 0, 0])
        let note = try XCTUnwrap(packets.last)
        XCTAssertEqual(Int(note[4]) | Int(note[5]) << 8, 44, "PARAM_CHANGED at the map's bulk offset")
        XCTAssertEqual(Int(note[6]) | Int(note[7]) << 8, 4)

        // An explicit default pair goes out normalized.
        XCTAssertTrue(vm.setCrossfeedPairMap(CrossfeedPairMap(bytes: [0x10, 0x23, 0x54, 0])))
        XCTAssertTrue(spinUntil(5) { vm.crossfeed.pairMap.bytes == [0, 0x23, 0, 0] })

        // An invalid map is refused before it is sent.
        let before = packets.count
        XCTAssertFalse(vm.setCrossfeedPairMap(CrossfeedPairMap(bytes: [0x11, 0, 0, 0])))
        settle()
        XCTAssertEqual(packets.count, before)
        XCTAssertEqual(vm.crossfeed.pairMap.bytes, [0, 0x23, 0, 0])
    }

    /// The firmware ignores an invalid map rather than refusing it; the
    /// published map follows the read-back, not the request.
    func testStateFollowsTheReadBackNotTheRequest() {
        let (fake, vm) = fakeVM()
        fetched(vm)
        // A write that bypasses the view model's check (another client).
        fake.sendControlRequest(request: REQ_EXTENSION, value: EXT_CROSSFEED_PAIR_MAP, index: EXT_WINDEX,
                                data: Data([0x11, 0, 0, 0]))
        vm.fetchCrossfeedPairMap()
        settle()
        XCTAssertEqual(vm.crossfeed.pairMap, .default)
    }

    func testCoreVoltageRefresh() throws {
        let (_, vm) = fakeVM()
        fetched(vm)
        let first = try XCTUnwrap(vm.coreVregStatus)
        vm.coreVregStatus = nil
        vm.refreshCoreVregStatus()
        XCTAssertTrue(spinUntil(5) { vm.coreVregStatus != nil })
        XCTAssertEqual(vm.coreVregStatus?.storedSel, first.storedSel)
        XCTAssertEqual(vm.coreVregStatus?.failedTrialUptimeS, 754)
    }

    func testDisconnectClearsTheProbe() {
        let (fake, vm) = fakeVM()
        fetched(vm)
        XCTAssertTrue(vm.coreVregSupported)
        fake.disconnect()
        XCTAssertTrue(spinUntil(5) { vm.extensionProbe == .unknown })
        XCTAssertNil(vm.coreVregStatus)
    }

    // MARK: - Probe failures

    /// The fake stays disconnected, so the view model's own connect path never
    /// runs and the probe below is the only one.
    private func probe(_ results: [Result<Data, LinkStatus>]) -> (ScriptedProbeTransport, DSPViewModel) {
        let fake = FakeTransport(autoSelect: false)
        let t = ScriptedProbeTransport(fake, listResults: results)
        let vm = DSPViewModel(transport: t)
        let done = expectation(description: "probe")
        DispatchQueue.global().async {
            vm.probeExtensions(force: true)
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 10)
        settle()
        return (t, vm)
    }

    func testAStallIsFinal() {
        let (t, vm) = probe([.failure(.error)])
        XCTAssertEqual(t.listCalls, 1)
        XCTAssertEqual(vm.extensionProbe, .unsupported)
    }

    /// DSPi Link: hubs classify the unlisted 0x00 as `config`, so a viewer or
    /// control session is denied; the features stay hidden.
    func testAHubDenialIsFinal() {
        let (t, vm) = probe([.failure(.denied)])
        XCTAssertEqual(t.listCalls, 1)
        XCTAssertEqual(vm.extensionProbe, .unsupported)
        XCTAssertFalse(vm.crossfeedPairMapSupported)
    }

    func testOtherFailuresAreRetriedOnce() {
        let (t, vm) = probe([.failure(.timeout), .success(Data([0x02, 0x00]))])
        XCTAssertEqual(t.listCalls, 2)
        XCTAssertEqual(vm.extensionProbe, .supported(DeviceExtensions(ids: [EXT_CORE_VREG])))
        XCTAssertTrue(vm.coreVregSupported)
        XCTAssertFalse(vm.crossfeedPairMapSupported)
    }

    func testTwoFailuresGiveUp() {
        let (t, vm) = probe([.failure(.busy), .failure(.timeout), .success(Data([0x01, 0x00]))])
        XCTAssertEqual(t.listCalls, 2)
        XCTAssertEqual(vm.extensionProbe, .unsupported)
    }

    func testAnEmptyListIsSupportedWithNothing() {
        let (_, vm) = probe([.success(Data())])
        XCTAssertEqual(vm.extensionProbe, .supported(.none))
        XCTAssertFalse(vm.crossfeedPairMapSupported)
        XCTAssertFalse(vm.coreVregSupported)
    }

    // MARK: - DSPi Link policy

    /// The policy table has no row for 0x00 and is not changed for it: hubs
    /// treat it as `config`, which only admin sessions may use.
    func testLinkPolicyTreatsTheExtensionAsAdminOnly() throws {
        let policy = try XCTUnwrap(LinkPolicy.bundled)
        XCTAssertNil(policy.entry(for: REQ_EXTENSION))
        XCTAssertEqual(policy.classify(code: REQ_EXTENSION, direction: .get), .config)
        XCTAssertTrue(policy.isAllowed(role: .admin, code: REQ_EXTENSION, direction: .get))
        XCTAssertFalse(policy.isAllowed(role: .control, code: REQ_EXTENSION, direction: .get))
        XCTAssertFalse(policy.isAllowed(role: .viewer, code: REQ_EXTENSION, direction: .get))
    }

    // MARK: - Over USB MIDI

    func testProbeAndWriteOverMIDI() throws {
        let fake = FakeTransport(autoSelect: false)
        fake.selectDevice(FakeTransport.demoDevice)
        let port = FakeMIDIControlPort(device: FakeMIDIDevice.backed(by: fake))
        let midi = MIDITransport(port: port, autoSelect: false, readOnly: false)
        let vm = DSPViewModel(transport: midi)
        midi.selectDevice(midi.availableDevices[0])
        XCTAssertTrue(spinUntil { midi.isConnected })
        fetched(vm, timeout: 60)
        XCTAssertTrue(vm.crossfeedPairMapSupported)
        XCTAssertNotNil(vm.coreVregStatus)
        XCTAssertTrue(vm.setCrossfeedPairMap(.oneDACPerEar))
        XCTAssertTrue(spinUntil(5) { vm.crossfeed.pairMap == .oneDACPerEar })
    }

    func testStockFirmwareOverMIDIAnswersError() {
        let fake = FakeTransport(autoSelect: false, extensions: false)
        fake.selectDevice(FakeTransport.demoDevice)
        let port = FakeMIDIControlPort(device: FakeMIDIDevice.backed(by: fake))
        let midi = MIDITransport(port: port, autoSelect: false, readOnly: false)
        midi.selectDevice(midi.availableDevices[0])
        XCTAssertTrue(spinUntil { midi.isConnected })
        let result = midi.getControlResult(request: REQ_EXTENSION, value: EXT_LIST, index: EXT_WINDEX,
                                           length: EXT_LIST_READ_LENGTH)
        XCTAssertEqual(result, .failure(.error))
        XCTAssertTrue(DSPViewModel.extensionProbeIsFinal(.error))
    }

    func testReadOnlyMIDIReadsExtensionsButNeverWritesThem() throws {
        let fake = FakeTransport(autoSelect: false)
        fake.selectDevice(FakeTransport.demoDevice)
        let port = FakeMIDIControlPort(device: FakeMIDIDevice.backed(by: fake))
        let midi = MIDITransport(port: port, autoSelect: false, readOnly: true)
        midi.selectDevice(midi.availableDevices[0])
        XCTAssertTrue(spinUntil { midi.isConnected })
        let list = try midi.getControlResult(request: REQ_EXTENSION, value: EXT_LIST, index: EXT_WINDEX,
                                             length: EXT_LIST_READ_LENGTH).get()
        XCTAssertEqual([UInt8](list), [0x01, 0x00, 0x02, 0x00])
        let set = midi.setControlResult(request: REQ_EXTENSION, value: EXT_CROSSFEED_PAIR_MAP, index: EXT_WINDEX,
                                        data: CrossfeedPairMap.oneDACPerEar.data)
        guard case .failure(.denied) = set else { return XCTFail("read-only mode sent an extension write: \(set)") }
    }
}

// MARK: - Presets

final class ExtensionChannelPresetTests: XCTestCase {

    func testFileCarriesThePairMapOnlyWhenPresent() throws {
        var doc = PresetDocument()
        doc.channels = [PresetDocument.ChannelBlock()]   // a reader requires channel data
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetDocumentFile.encode(doc)) as? [String: Any])
        XCTAssertNil((json["crossfeed"] as? [String: Any])?["pairMap"], "absent unless the device has the map")

        doc.crossfeed.pairMap = [2, 19, 0, 0]
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetDocumentFile.encode(doc)) as? [String: Any])
        XCTAssertEqual((json["crossfeed"] as? [String: Any])?["pairMap"] as? [Int], [2, 19, 0, 0])
        let back = try PresetDocumentFile.decode(PresetDocumentFile.encode(doc))
        XCTAssertEqual(back.crossfeed.pairMap, [2, 19, 0, 0])
        XCTAssertEqual(back.crossfeed.pairMap(pairCount: 4), .oneDACPerEar)
    }

    func testAndroidWrittenBlockDecodes() throws {
        let text = """
        {"schemaVersion": 1,
         "channels": [{"channelId": 0}],
         "crossfeed": {"enabled": true, "preset": 0, "freqHz": 700, "feedDb": 4.5, "itd": true,
                       "outputPairMask": 3, "pairMap": [2, 19, 0, 0]}}
        """
        let doc = try PresetDocumentFile.decode(Data(text.utf8))
        XCTAssertEqual(doc.crossfeed.outputPairMask, 3)
        XCTAssertEqual(doc.crossfeed.pairMap(pairCount: 2), .oneDACPerEar)
    }

    func testImportRules() {
        var block = PresetDocument.CrossfeedBlock()
        XCTAssertNil(block.pairMap(pairCount: 4), "absent: leave the device's map alone")
        block.pairMap = [0x10, 0x23, 0x54, 0x76]
        XCTAssertEqual(block.pairMap(pairCount: 4)?.bytes, [0, 0x23, 0, 0], "normalized")
        block.pairMap = [0x76, 0x54, 0x32, 0x10]
        XCTAssertEqual(block.pairMap(pairCount: 2), .default, "a wider platform's map falls back to default")
        block.pairMap = [17, 0, 0, 0]
        XCTAssertEqual(block.pairMap(pairCount: 4), .default, "invalid: default")
        block.pairMap = [2, 19, 0, 0, 0]
        XCTAssertEqual(block.pairMap(pairCount: 4), .default, "too long: default")
        block.pairMap = [2, 300, -1, 0]
        XCTAssertEqual(block.pairMap(pairCount: 4), .default, "out-of-range values clamp, then fail validation")
        block.pairMap = [2]
        XCTAssertEqual(block.pairMap(pairCount: 4), .default, "[2, 0, 0, 0] shares output 2 with pair 2")
    }

    func testCaptureWritesTheMapOnlyFromADeviceWithIt() throws {
        for extensions in [true, false] {
            let fake = FakeTransport(autoSelect: false, extensions: extensions)
            let vm = DSPViewModel(transport: fake)
            fake.selectDevice(FakeTransport.demoDevice)
            fake.sendControlRequest(request: REQ_EXTENSION, value: EXT_CROSSFEED_PAIR_MAP, index: EXT_WINDEX,
                                    data: CrossfeedPairMap.oneDACPerEar.data)
            let done = expectation(description: "fetch")
            DispatchQueue.global().async { vm.fetchAll(); DispatchQueue.main.async { done.fulfill() } }
            wait(for: [done], timeout: 30)
            let doc = PresetDocument.capture(from: vm)
            XCTAssertEqual(doc.crossfeed.pairMap, extensions ? [2, 19, 0, 0] : nil)
        }
    }

    func testSnapshotDiffNamesEachChangedPair() {
        let vm = DSPViewModel(transport: FakeTransport(autoSelect: false))
        let old = vm.captureSnapshot()
        XCTAssertEqual(old.crossfeedPairMap, .default)
        var new = old
        new.crossfeedPairMap = .oneDACPerEar
        let lines = PresetSnapshot.diff(from: old, to: new, channelNames: vm.channelNames).changes.map(\.description)
        XCTAssertEqual(lines, ["Crossfeed pair 1 outputs: 1/2 → 3/1", "Crossfeed pair 2 outputs: 3/4 → 4/2"])
        XCTAssertNotEqual(old, new)
    }
}

// MARK: - Test transports

/// Counts the extension GETs that pass through to a real fake.
final class CountingTransport: ForwardingTransport {
    private let lock = NSLock()
    private var counts: [UInt16: Int] = [:]

    func extensionGets(_ id: UInt16) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id] ?? 0 }

    override func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        if request == REQ_EXTENSION { lock.lock(); counts[value, default: 0] += 1; lock.unlock() }
        return super.getControlResult(request: request, value: value, index: index, length: length)
    }
}

/// Answers EXT_LIST from a script, then STALLs; everything else goes to the fake.
final class ScriptedProbeTransport: ForwardingTransport {
    private let lock = NSLock()
    private var script: [Result<Data, LinkStatus>]
    private(set) var listCalls = 0

    init(_ inner: any DeviceTransport, listResults: [Result<Data, LinkStatus>]) {
        script = listResults
        super.init(inner)
    }

    override func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        guard request == REQ_EXTENSION, value == EXT_LIST else {
            return super.getControlResult(request: request, value: value, index: index, length: length)
        }
        lock.lock(); defer { lock.unlock() }
        listCalls += 1
        return script.isEmpty ? .failure(.error) : script.removeFirst()
    }
}

/// A DeviceTransport that hands everything to another one.
class ForwardingTransport: DeviceTransport {
    let inner: any DeviceTransport
    init(_ inner: any DeviceTransport) { self.inner = inner }

    var session: LinkSessionID { inner.session }
    var generation: UInt64 { inner.generation }
    var isConnected: Bool { inner.isConnected }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { inner.isConnectedPublisher }
    var availableDevices: [DSPiDevice] { inner.availableDevices }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { inner.availableDevicesPublisher }
    var selectedDevice: DSPiDevice? { inner.selectedDevice }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { inner.selectedDevicePublisher }
    var errorMessage: String? { inner.errorMessage }
    var errorMessagePublisher: AnyPublisher<String?, Never> { inner.errorMessagePublisher }
    func selectDevice(_ device: DSPiDevice) { inner.selectDevice(device) }
    func reconnect() { inner.reconnect() }
    func disconnect() { inner.disconnect() }
    func markDisconnected() { inner.markDisconnected() }
    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        inner.sendControlRequest(request: request, value: value, index: index, data: data)
    }
    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus> {
        inner.getControlResult(request: request, value: value, index: index, length: length)
    }
    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        inner.addNotificationObserver(handler)
    }
}
