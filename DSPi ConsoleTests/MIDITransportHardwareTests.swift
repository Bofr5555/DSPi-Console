import XCTest
@testable import DSPi_Console

/// Read-only measurements on a real DSPi over its USB MIDI control port
/// (macOS).  Opt-in: runs only with DSPI_MIDI_HW=1 in the test environment
/// (`TEST_RUNNER_DSPI_MIDI_HW=1 xcodebuild test ...`), and only when the
/// host app runs the MIDI transport read-only (UserDefaults
/// `LocalTransport` = midi, `MIDIReadOnly` = YES), so nothing this test or
/// the app sends can change the device.  It measures through the app's own
/// transport, so the app's polling shares the queue as it would in use.
final class MIDITransportHardwareTests: XCTestCase {

    func testReadOnlyRoundTripsOnARealDSPi() throws {
        guard ProcessInfo.processInfo.environment["DSPI_MIDI_HW"] == "1" else {
            throw XCTSkip("Set DSPI_MIDI_HW=1 to run against a real DSPi")
        }
        #if os(macOS)
        guard AppState.usesMIDITransport else { throw XCTSkip("Host app is not on the MIDI transport (LocalTransport=midi)") }
        let midi = AppState.shared.midiTransport
        #else
        let midi = AppState.shared.midiTransport
        #endif
        guard midi.readOnly else {
            XCTFail("Refusing to talk to a real device: the MIDI transport is not read-only (MIDIReadOnly=YES)")
            return
        }
        _ = AppState.shared.transport
        guard spinUntil(30, { midi.isConnected }) else { throw XCTSkip("No DSPi on MIDI") }
        // Let the app's connect-time read finish.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let connectStats = midi.stats

        var report: [String] = []
        report.append("device: \(midi.selectedDevice?.displayName ?? "?") serial \(midi.selectedDevice?.serial ?? "?") location 0x\(String(midi.selectedDevice?.locationID ?? 0, radix: 16))")
        if let first = connectStats.bulkReads.first {
            report.append(String(format: "connect-time 0xA0 (app): %d B in %.1f ms", first.bytes, first.seconds * 1000))
        }
        report.append("app connect: \(connectStats.requests) requests, \(connectStats.timeouts) timeouts, \(connectStats.refusedReadOnly) refused by read-only")

        var notifications = 0
        let token = midi.addNotificationObserver { _ in notifications += 1 }

        func measure(_ label: String, _ n: Int, _ request: UInt8, value: UInt16 = 0, index: UInt16 = 2,
                     length: UInt16) -> [TimeInterval] {
            var times: [TimeInterval] = []
            var failures: [LinkStatus] = []
            let done = expectation(description: label)
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<n {
                    let t0 = Date()
                    let r = midi.getControlResult(request: request, value: value, index: index, length: length)
                    let dt = Date().timeIntervalSince(t0)
                    switch r {
                    case .success: times.append(dt)
                    case .failure(let s): failures.append(s)
                    }
                }
                done.fulfill()
            }
            wait(for: [done], timeout: Double(n) * 6)
            let sorted = times.sorted()
            func pct(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
            let mean = sorted.isEmpty ? .nan : sorted.reduce(0, +) / Double(sorted.count) * 1000
            report.append(String(format: "%@: n=%d ok=%d mean %.2f ms, p50 %.2f, p95 %.2f, max %.2f", label, n, sorted.count,
                                 mean, pct(0.5), pct(0.95), sorted.last.map { $0 * 1000 } ?? .nan)
                          + (failures.isEmpty ? "" : " failures \(failures)"))
            XCTAssertEqual(failures, [], label)
            return times
        }

        _ = measure("GET 0x7F platform", 50, REQ_GET_PLATFORM, length: 7)
        _ = measure("GET 0xD3 master volume", 100, REQ_GET_MASTER_VOLUME, length: 4)
        _ = measure("GET 0x50/9 status (meters)", 100, REQ_GET_STATUS, value: 9, index: 0, length: 41)
        let bulk = measure("GET 0xA0 all params", 10, REQ_GET_ALL_PARAMS, length: UInt16(BULK_PARAMS_SIZE))
        if let best = bulk.min() {
            report.append(String(format: "0xA0 best %.1f ms = %.0f kB/s of SysEx (7028 B message)", best * 1000, 7028 / best / 1000))
        }

        RunLoop.current.run(until: Date().addingTimeInterval(5))
        token.cancel()
        report.append("notifications during the run: \(notifications)")
        report.append("transport totals:\n" + midi.statsSummary())

        let text = report.joined(separator: "\n")
        print("MIDI hardware report\n" + text)
        try? text.write(toFile: NSTemporaryDirectory() + "midi_hw_report.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(midi.stats.timeouts, 0)
    }
}
