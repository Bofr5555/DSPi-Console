import XCTest
@testable import DSPi_Console

/// The extension channel on a real DSPi running the bofr firmware, over its
/// USB MIDI control port (macOS with `-LocalTransport midi`, or the iOS
/// Simulator through the MIDI relay).  Opt-in: DSPI_EXT_HW=1 in the test
/// environment (`TEST_RUNNER_DSPI_EXT_HW=1`), and the MIDI transport must not
/// be read-only, since the test writes the pair map.
///
/// Sequence: EXT_LIST; read the pair map; write a different valid map and
/// read it back (also from the bulk image at offset 44); write an invalid
/// map, which the firmware ignores; restore the original map and verify it
/// (restored on every exit); read the core-voltage status; check that the
/// refusals (OUT EXT_LIST, a short OUT, an unknown sub-command) answer ERROR.
/// The core voltage is never written.
final class ExtensionChannelHardwareTests: XCTestCase {

    func testExtensionChannelOnARealDSPi() throws {
        guard ProcessInfo.processInfo.environment["DSPI_EXT_HW"] == "1" else {
            throw XCTSkip("Set DSPI_EXT_HW=1 to run against a real DSPi with the extension channel")
        }
        #if os(macOS)
        guard AppState.usesMIDITransport else { throw XCTSkip("Host app is not on the MIDI transport (LocalTransport=midi)") }
        #endif
        let midi = AppState.shared.midiTransport
        guard !midi.readOnly else { throw XCTSkip("MIDI transport is read-only (MIDIReadOnly); this test writes the pair map") }
        _ = AppState.shared.transport
        guard spinUntil(30, { midi.isConnected }) else { throw XCTSkip("No DSPi on MIDI") }
        RunLoop.current.run(until: Date().addingTimeInterval(5))       // the app's connect read settles

        var report: [String] = ["device: \(midi.selectedDevice?.displayName ?? "?") serial \(midi.selectedDevice?.serial ?? "?")"]
        defer {
            let text = report.joined(separator: "\n")
            print("Extension channel report\n" + text)
            try? text.write(toFile: NSTemporaryDirectory() + "ext_channel_report.txt", atomically: true, encoding: .utf8)
        }

        // Off the main thread like the console's own reads.
        func onQueue<T>(_ body: @escaping () -> T) -> T {
            var out: T?
            let done = expectation(description: "transfer")
            DispatchQueue.global(qos: .userInitiated).async { out = body(); done.fulfill() }
            wait(for: [done], timeout: 30)
            return out!
        }
        func get(_ value: UInt16, _ length: UInt16) -> Result<Data, LinkStatus> {
            onQueue { midi.getControlResult(request: REQ_EXTENSION, value: value, index: EXT_WINDEX, length: length) }
        }
        func set(_ value: UInt16, _ data: Data) -> Result<Void, LinkStatus> {
            onQueue { midi.setControlResult(request: REQ_EXTENSION, value: value, index: EXT_WINDEX, data: data) }
        }
        func readMap() throws -> CrossfeedPairMap {
            let data = try get(EXT_CROSSFEED_PAIR_MAP, UInt16(CrossfeedPairMap.byteCount)).get()
            XCTAssertEqual(data.count, CrossfeedPairMap.byteCount)
            return CrossfeedPairMap(data)
        }
        func hex(_ m: CrossfeedPairMap) -> String { m.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

        // Platform, for the pair count.
        let platformReply = try onQueue { midi.getControlResult(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 7) }.get()
        let fw = FirmwareVersion.fromPlatformReply([UInt8](platformReply))
        let pairCount = fw?.platform == 0 ? 2 : 4     // 0 = RP2040, 1 = RP2350
        report.append("platform \(fw.map { "\($0.platform)" } ?? "?"), firmware \(fw.map { "\($0.version)" } ?? "?"), \(pairCount) crossfeed pairs")

        // 1. Discovery.
        let list = DeviceExtensions(listReply: try get(EXT_LIST, EXT_LIST_READ_LENGTH).get())
        report.append("EXT_LIST: \(list.ids.sorted().map { String(format: "0x%04X", $0) })")
        XCTAssertTrue(list.crossfeedPairMap, "EXT_CROSSFEED_PAIR_MAP listed")
        XCTAssertTrue(list.coreVreg, "EXT_CORE_VREG listed")

        // The app's own probe through its own transport agrees.
        let vm = AppState.shared.viewModel
        XCTAssertTrue(spinUntil(10) { vm.extensionProbe != .unknown })
        XCTAssertEqual(vm.extensionProbe.extensions, list, "the console's connect-time probe")

        // 2. The pair map: read, change, verify, restore.
        if list.crossfeedPairMap {
            let original = try readMap()
            report.append("pair map, original: \(hex(original))")
            XCTAssertTrue(original.isValid(pairCount: pairCount), "the device reports a valid map")
            XCTAssertEqual(original, original.normalized, "the device reports the map normalized")

            var restored = false
            defer {
                if !restored {
                    _ = set(EXT_CROSSFEED_PAIR_MAP, original.data)
                    report.append("pair map restored on the failure path: \((try? readMap()).map(hex) ?? "read failed")")
                }
            }

            let candidates = [CrossfeedPairMap.oneDACPerEar, .default, .from(pairs: [(1, 0), (3, 2)])]
            let target = try XCTUnwrap(candidates.first { !$0.samePairing(as: original) }).normalized
            XCTAssertNoThrow(try set(EXT_CROSSFEED_PAIR_MAP, target.data).get(), "write \(hex(target))")
            let back = try readMap()
            report.append("pair map, written \(hex(target)), read back \(hex(back))")
            XCTAssertEqual(back, target)

            // The same map in the bulk image, at offset 44.
            let bulk = try onQueue {
                midi.getControlResult(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE)
            }.get()
            XCTAssertEqual(CrossfeedPairMap(bulk: bulk), target, "bulk offset 44")
            report.append("bulk image (\(bulk.count) B) offset 44: \(hex(CrossfeedPairMap(bulk: bulk)))")

            // An invalid map is acknowledged and ignored.
            let invalid = CrossfeedPairMap(bytes: [0x11, 0, 0, 0])
            let invalidResult = set(EXT_CROSSFEED_PAIR_MAP, invalid.data)
            let afterInvalid = try readMap()
            report.append("invalid map \(hex(invalid)): status \(invalidResult), read back \(hex(afterInvalid))")
            XCTAssertEqual(afterInvalid, target, "the firmware ignores an invalid map")

            XCTAssertNoThrow(try set(EXT_CROSSFEED_PAIR_MAP, original.data).get(), "restore")
            let restoredMap = try readMap()
            restored = restoredMap == original
            report.append("pair map, restored: \(hex(restoredMap))")
            XCTAssertEqual(restoredMap, original, "original map restored")
        }

        // 3. Core voltage, read only.
        if list.coreVreg {
            let raw = try get(EXT_CORE_VREG, UInt16(CoreVregStatus.size)).get()
            XCTAssertEqual(raw.count, CoreVregStatus.size)
            let s = try XCTUnwrap(CoreVregStatus(raw))
            let platform = pairCount == 2 ? "RP2040" : "RP2350"
            func v(_ c: UInt8) -> String { VregVoltage.label(c, platform: platform) }
            report.append("core vreg: raw \(raw.map { String(format: "%02X", $0) }.joined(separator: " "))")
            report.append("  live \(v(s.liveVreg)), stored \(s.storedSel == 0 ? "build default" : v(s.storedSel)), default \(v(s.defaultVreg)), flags 0x\(String(format: "%02X", s.flags)), hangs \(s.hangCount), trial \(s.trialActive ? v(s.trialVreg) : "none"), failed trial \(s.hasFailedTrial ? "\(v(s.failedTrialVreg)) after \(formatUptime(s.failedTrialUptimeS))" : "none"), uptime \(formatUptime(s.uptimeS))")
            XCTAssertTrue((0x0C...0x0F).contains(s.liveVreg), "live voltage within 1.15-1.30 V")
            XCTAssertTrue((0x0C...0x0F).contains(s.defaultVreg), "build default within 1.15-1.30 V")
            XCTAssertTrue(s.storedSel == 0 || (s.defaultVreg...0x0F).contains(s.storedSel), "stored selection at or above the floor")
            XCTAssertGreaterThan(s.uptimeS, 0)
        }

        // 4. Refusals answer ERROR (STALL on USB).
        let outList = set(EXT_LIST, Data([0, 0]))
        let shortMap = set(EXT_CROSSFEED_PAIR_MAP, Data([0, 0, 0]))
        let unknown = get(0x7FFF, 16)
        report.append("refusals: OUT EXT_LIST \(outList), 3-byte map \(shortMap), IN 0x7FFF \(unknown)")
        if case .failure(.error) = outList {} else { XCTFail("OUT EXT_LIST: \(outList)") }
        if case .failure(.error) = shortMap {} else { XCTFail("short OUT pair map: \(shortMap)") }
        XCTAssertEqual(unknown, .failure(.error), "unknown sub-command")
        if list.crossfeedPairMap {
            XCTAssertNotNil(try? readMap(), "the device still answers after the refusals")
        }
    }
}
