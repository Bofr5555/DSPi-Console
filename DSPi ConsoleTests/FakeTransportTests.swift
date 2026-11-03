import XCTest
import Combine
@testable import DSPi_Console

/// The demo device (`FakeTransport`): it must answer like the captured board
/// (RP2350, firmware 1.1.6-beta5, WireBulkParams V32), keep what the console
/// writes, and decode through the real view model to the values the capture
/// holds (dspi-ios fixtures/README.md; the same values as the Android port's
/// `dspstate_v32.json`).
final class FakeTransportTests: XCTestCase {

    private func connectedFake() -> FakeTransport {
        let fake = FakeTransport(autoSelect: false)
        fake.selectDevice(FakeTransport.demoDevice)
        return fake
    }

    private func get(_ fake: FakeTransport, _ request: UInt8, value: UInt16 = 0, index: UInt16 = 2,
                     length: UInt16) -> Data? {
        fake.getControlRequest(request: request, value: value, index: index, length: length)
    }

    // MARK: - Wire level

    func testPlatformIsTheCapturedRP2350Beta5() throws {
        let fake = connectedFake()
        let reply = try XCTUnwrap(get(fake, REQ_GET_PLATFORM, length: 7))
        XCTAssertEqual([UInt8](reply), [1, 1, 0x16, 9, 1, 6, 5])
        let decoded = FirmwareVersion.fromPlatformReply([UInt8](reply))
        XCTAssertEqual(decoded?.platform, 1)
        XCTAssertEqual(decoded?.version, FirmwareVersion(1, 1, 6, 5))
    }

    func testBulkImageIsV32() throws {
        let fake = connectedFake()
        let bulk = try XCTUnwrap(get(fake, REQ_GET_ALL_PARAMS, length: BULK_PARAMS_SIZE))
        XCTAssertEqual(bulk.count, Int(BULK_PARAMS_SIZE))
        XCTAssertEqual(Int(bulk[0]), WIRE_FORMAT_VERSION)
        XCTAssertEqual(bulk[1], 1)    // RP2350
        XCTAssertEqual(bulk[2], 17)   // channels
        XCTAssertEqual(bulk[3], 9)    // outputs
        XCTAssertEqual(bulk[4], 8)    // inputs
    }

    func testNothingAnswersWhileDisconnected() {
        let fake = FakeTransport(autoSelect: false)
        XCTAssertEqual(fake.getControlResult(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 7),
                       .failure(.noDevice))
    }

    func testMetersMoveOnTheEnabledChannels() throws {
        let fake = connectedFake()
        // 17 channels: peaks u16[17], cpu0, cpu1, clip u32, active inputs.
        let length = UInt16(17 * 2 + 7)
        let status = try XCTUnwrap(get(fake, REQ_GET_STATUS, value: 9, index: 0, length: length))
        XCTAssertEqual(status.count, Int(length))
        func peak(_ ch: Int) -> UInt16 { UInt16(status[ch * 2]) | UInt16(status[ch * 2 + 1]) << 8 }
        XCTAssertGreaterThan(peak(0), 0)          // USB 1
        XCTAssertGreaterThan(peak(8), 0)          // SPDIF 1 L, enabled in the capture
        XCTAssertEqual(peak(10), 0)               // SPDIF 2 L, disabled in the capture
        XCTAssertEqual(status[17 * 2 + 6], 2)     // two active USB inputs
    }

    func testSetPatchesTheImageAndNotifies() throws {
        let fake = connectedFake()
        var packets: [Data] = []
        let token = fake.addNotificationObserver { packets.append($0.packet) }
        defer { token.cancel() }

        // Band 3 of channel 0: peaking, 1 kHz, Q 2, +3 dB.
        var packet = Data([0, 2, UInt8(FilterType.peaking.rawValue), 0])
        for value: Float in [1000, 2, 3] { withUnsafeBytes(of: value) { packet.append(contentsOf: $0) } }
        fake.sendControlRequest(request: REQ_SET_EQ_PARAM, value: 0, index: 0, data: packet)

        let bulk = try XCTUnwrap(get(fake, REQ_GET_ALL_PARAMS, length: BULK_PARAMS_SIZE))
        let base = BULK_EQ_OFFSET + 2 * WIRE_BAND_PARAMS_SIZE
        XCTAssertEqual(bulk[base], UInt8(FilterType.peaking.rawValue))
        let gain = bulk.withUnsafeBytes { $0.load(fromByteOffset: base + 12, as: Float.self) }
        XCTAssertEqual(gain, 3)

        let notification = try XCTUnwrap(packets.last)
        XCTAssertEqual(notification[0], 0x02)     // v2
        XCTAssertEqual(notification[1], 0x02)     // PARAM_CHANGED
        XCTAssertEqual(Int(notification[4]) | Int(notification[5]) << 8, base)
        XCTAssertEqual(notification[8], 1)        // PARAM_SRC_HOST_SET
    }

    func testPresetsSaveLoadAndName() throws {
        let fake = connectedFake()
        XCTAssertEqual(get(fake, REQ_PRESET_SAVE, value: 4, length: 1), Data([PRESET_OK]))
        fake.sendControlRequest(request: REQ_PRESET_SET_NAME, value: 4, index: 2, data: Data("Late night".utf8))
        let dir = try XCTUnwrap(get(fake, REQ_PRESET_GET_DIR, length: 7))
        let occupied = UInt16(dir[0]) | UInt16(dir[1]) << 8
        XCTAssertNotEqual(occupied & (1 << 4), 0)
        XCTAssertEqual(dir[4], 4)                 // last active
        let name = try XCTUnwrap(get(fake, REQ_PRESET_GET_NAME, value: 4, length: 32))
        XCTAssertEqual(String(decoding: name.prefix { $0 != 0 }, as: UTF8.self), "Late night")
        XCTAssertEqual(get(fake, REQ_PRESET_LOAD, value: 1, length: 1), Data([PRESET_OK]))
        XCTAssertEqual(get(fake, REQ_PRESET_GET_ACTIVE, length: 1), Data([1]))
    }

    func testEchoReadsBackWhatASetWrote() {
        let fake = connectedFake()
        var cutoff: Float = 95
        fake.sendControlRequest(request: REQ_SET_PSYBASS_CUTOFF, value: 0, index: 0,
                                data: Data(bytes: &cutoff, count: 4))
        let back = get(fake, REQ_GET_PSYBASS_CUTOFF, index: 0, length: 4)
        XCTAssertEqual(back?.withUnsafeBytes { $0.load(as: Float.self) }, 95)
    }

    // MARK: - Through the view model

    /// The connect-time fetch decodes the capture to its known values, and the
    /// only reads left unanswered are the documented gaps (features the demo
    /// device reports as absent).
    func testFetchAllDecodesTheCapture() {
        let fake = FakeTransport(autoSelect: false)
        let vm = DSPViewModel(transport: fake)
        fake.selectDevice(FakeTransport.demoDevice)

        let fetched = expectation(description: "fetchAll")
        DispatchQueue.global().async {
            vm.fetchAll()
            // Let the main-queue publications from the fetch land.
            DispatchQueue.main.async { fetched.fulfill() }
        }
        wait(for: [fetched], timeout: 30)

        XCTAssertEqual(vm.platformName, "RP2350")
        XCTAssertEqual(vm.outputEnabled, [true, true, false, false, false, false, false, false, false])
        XCTAssertEqual(vm.masterVolumeDB, -20)
        XCTAssertEqual(Array(vm.channelNames.prefix(2)), ["USB 1", "USB 2"])
        XCTAssertEqual(vm.channelNames[8], "SPDIF 1 L")
        XCTAssertTrue(vm.matrixRouting[0][0])
        XCTAssertTrue(vm.matrixRouting[1][1])
        XCTAssertTrue(vm.lgSoundSyncEnabled)
        XCTAssertFalse(vm.crossfeedEnabled)

        let knownGaps: Set<UInt8> = [
            REQ_RTA_GET_CAPS, REQ_SIGGEN_GET_CAPS, REQ_GET_CS_CAPS, REQ_GET_CTRL_IFACE_STATUS,
            REQ_GET_ADAT_STATUS, REQ_GET_ADAT_INPUT_STATUS, REQ_GET_SPDIF_RX_PIN,
            REQ_GET_SPDIF_INPUT_CONFIG, REQ_GET_I2S_RX_PIN, REQ_GET_DAC_HW_MUTE_CONFIG,
        ]
        let unexpected = fake.unansweredRequests.filter { line in
            guard let hex = line.split(separator: " ").first, let op = UInt8(hex.dropFirst(2), radix: 16) else { return true }
            return !knownGaps.contains(op)
        }
        XCTAssertEqual(unexpected, [], "connect-time reads the demo device does not answer")
    }
}
