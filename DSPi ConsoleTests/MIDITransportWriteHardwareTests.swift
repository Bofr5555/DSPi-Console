import XCTest
@testable import DSPi_Console

/// Restore-verified writes on a real DSPi over its USB MIDI control port
/// (macOS, or the iOS Simulator through the relay).  Opt-in twice over:
/// DSPI_MIDI_HW_WRITE=1 in the test environment
/// (`TEST_RUNNER_DSPI_MIDI_HW_WRITE=1`) and DSPI_MIDI_BACKUP_DIR naming a
/// directory with the unit's reference state.  The sequence is
/// `RestoreVerifiedWrites`.
final class MIDITransportWriteHardwareTests: XCTestCase {

    func testRestoreVerifiedWritesOnARealDSPi() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DSPI_MIDI_HW_WRITE"] == "1" else { throw XCTSkip("Set DSPI_MIDI_HW_WRITE=1 to write to a real DSPi") }
        guard let dir = env["DSPI_MIDI_BACKUP_DIR"] else { throw XCTSkip("Set DSPI_MIDI_BACKUP_DIR") }
        #if os(macOS)
        guard AppState.usesMIDITransport else { throw XCTSkip("Host app is not on the MIDI transport") }
        #endif
        let midi = AppState.shared.midiTransport
        guard !midi.readOnly else { throw XCTSkip("MIDI transport is read-only") }
        _ = AppState.shared.transport
        guard spinUntil(30, { midi.isConnected }) else { throw XCTSkip("No DSPi on MIDI") }
        RunLoop.current.run(until: Date().addingTimeInterval(5))       // app connect read settles

        let writes = RestoreVerifiedWrites(transport: midi)
        writes.bulkStats = {
            guard let a1 = midi.stats.roundTrip[0xA1] else { return [] }
            return [String(format: "0xA1 transaction (7032 B SysEx out, reply in): n=%d mean %.1f ms min %.1f max %.1f",
                           a1.count, a1.mean * 1000, a1.min * 1000, a1.max * 1000),
                    "notification sequence gaps: \(midi.stats.sequenceGaps)"]
        }
        let token = writes.observe()
        let failure = try writes.run(referenceDirectory: dir)
        token.cancel()
        let text = (writes.report + ["transport totals:\n" + midi.statsSummary()]).joined(separator: "\n")
        print("MIDI write report\n" + text)
        try? text.write(toFile: NSTemporaryDirectory() + "midi_write_report.txt", atomically: true, encoding: .utf8)
        if let f = failure { XCTFail(f) }
    }
}
