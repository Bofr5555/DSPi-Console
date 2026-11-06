#if os(iOS)
import XCTest
import Combine
@testable import DSPi_Console

/// The iOS app as a DSPi Link client of a real hub: the macOS Console in the
/// same VM sharing its USB DSPi (LinkHubHarnessTests).  Opt-in:
/// DSPI_LINK_HW=1, plus DSPI_LINK_BACKUP_DIR for the write part.  Through
/// the app's own CompositeTransport it discovers the hub (Bonjour, with a
/// typed address as the fallback), pairs if asked (answering the app's
/// pairing request with the PIN the hub published), connects, measures read
/// round trips, waits for a change made on the Mac, and runs the
/// restore-verified writes.  The report goes to DSPI_LINK_DIR/ios_link_report.txt.
final class LinkHardwareTests: XCTestCase {

    private var report: [String] = []

    private func hubInfo(_ dir: String) -> (pin: String, port: Int, name: String, id: String)? {
        guard let text = try? String(contentsOfFile: dir + "/hub.txt", encoding: .utf8) else { return nil }
        let l = text.components(separatedBy: "\n")
        guard l.count >= 4, let port = Int(l[1]) else { return nil }
        return (l[0], port, l[2], l[3])
    }

    private func command(_ dir: String, _ cmd: String) {
        try? cmd.write(toFile: dir + "/cmd", atomically: true, encoding: .utf8)
    }

    @MainActor
    func testDiscoverPairReadWriteOverDSPiLink() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DSPI_LINK_HW"] == "1" else { throw XCTSkip("Set DSPI_LINK_HW=1 with a hub running") }
        let dir = env["DSPI_LINK_DIR"] ?? "/Users/user/probe/link"
        guard var hub = hubInfo(dir) else { throw XCTSkip("No hub.txt in \(dir): start LinkHubHarnessTests first") }
        defer {
            let text = report.joined(separator: "\n")
            print("DSPi Link report\n" + text)
            try? text.write(toFile: dir + "/ios_link_report.txt", atomically: true, encoding: .utf8)
        }

        // Answer the app's own pairing request (the sheet) with the hub's PIN;
        // a PIN already used asks the hub for a new window first.
        var prompts = 0
        var pinUsed = false
        let pairing = IOSLinkPairing.shared.$request.sink { request in
            guard request != nil else { return }
            prompts += 1
            DispatchQueue.main.async {
                if pinUsed {
                    self.command(dir, "pin")
                    let old = hub.pin
                    let until = Date().addingTimeInterval(5)
                    while Date() < until, (self.hubInfo(dir)?.pin ?? old) == old {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    }
                    hub = self.hubInfo(dir) ?? hub
                }
                pinUsed = true
                IOSLinkPairing.shared.answer(hub.pin)
            }
        }
        defer { pairing.cancel() }

        // Discovery.
        let coordinator = AppState.shared.linkClientCoordinator
        let composite = AppState.shared.transport
        let t0 = Date()
        coordinator.lookForHubs = true
        let found = spinUntil(20) { coordinator.hubs.contains { $0.id == hub.id } }
        if found {
            report.append(String(format: "discovery: hub %@ found by Bonjour after %.1f s", hub.name, Date().timeIntervalSince(t0)))
        } else {
            report.append("discovery: not found by Bonjour within 20 s, adding 127.0.0.1:\(hub.port) by hand")
            coordinator.addManual("127.0.0.1:\(hub.port)")
        }
        guard spinUntil(30, { composite.availableDevices.contains { $0.hub?.hubID == hub.id } })
                || spinUntil(30, { composite.availableDevices.contains { $0.isRemote } }) else {
            return XCTFail("no device from the hub in the device list")
        }
        let device = composite.availableDevices.first { $0.hub?.hubID == hub.id }
            ?? composite.availableDevices.first { $0.isRemote }!
        report.append("device: \(device.displayName) serial \(device.serial)")

        // Connect (and pair if asked).
        let t1 = Date()
        composite.selectDevice(device)
        guard spinUntil(45, { composite.isConnected && composite.isRemoteActive }) else {
            return XCTFail("did not connect (pairing prompts: \(prompts), error: \(composite.errorMessage ?? "none"))")
        }
        report.append(String(format: "connected after %.2f s, pairing prompts %d, session %d",
                             Date().timeIntervalSince(t1), prompts, Int(composite.session)))
        RunLoop.current.run(until: Date().addingTimeInterval(6))        // the view model's connect read

        // Read round trips, off the main thread (a main-thread GET over Link
        // answers at once without a ready session, by design).
        func measure(_ label: String, _ n: Int, _ request: UInt8, value: UInt16 = 0, index: UInt16 = 2,
                     length: UInt16) {
            var times: [TimeInterval] = []
            var failures = 0
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<n {
                    let s = Date()
                    if case .success = composite.getControlResult(request: request, value: value, index: index, length: length) {
                        times.append(Date().timeIntervalSince(s))
                    } else { failures += 1 }
                }
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            let s = times.sorted()
            func p(_ q: Double) -> Double { s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count) * q))] * 1000 }
            report.append(String(format: "%@: n=%d ok=%d mean %.2f ms, p50 %.2f, p95 %.2f, max %.2f", label, n, s.count,
                                 s.isEmpty ? .nan : s.reduce(0, +) / Double(s.count) * 1000, p(0.5), p(0.95),
                                 (s.last ?? .nan) * 1000))
            XCTAssertEqual(failures, 0, label)
        }
        measure("GET 0x7F platform", 50, REQ_GET_PLATFORM, length: 7)
        measure("GET 0xD3 master volume", 100, REQ_GET_MASTER_VOLUME, length: 4)
        measure("GET 0x50/9 status (meters)", 100, REQ_GET_STATUS, value: 9, index: 0, length: 41)
        measure("GET 0xA0 all params (snapshot when offered)", 10, REQ_GET_ALL_PARAMS, length: UInt16(BULK_PARAMS_SIZE))

        // A change made on the Mac reaches this client.
        var foreign: [LinkNotification] = []
        let watch = composite.addNotificationObserver { n in
            if n.eventID == 0x02, n.origin != composite.session { foreign.append(n) }
        }
        try? FileManager.default.removeItem(atPath: dir + "/change.txt")
        command(dir, "change")
        let gotIt = spinUntil(15) { !foreign.isEmpty }
        _ = spinUntil(10) { FileManager.default.fileExists(atPath: dir + "/change.txt") }
        watch.cancel()
        let change = (try? String(contentsOfFile: dir + "/change.txt", encoding: .utf8)) ?? "?"
        if gotIt, let first = foreign.first, let sent = Double(change.split(separator: " ").first ?? "") {
            report.append(String(format: "Mac-side change: %d notification(s), first after %.1f ms (origin %d), Mac restore: %@",
                                 foreign.count, (first.receivedAt.timeIntervalSince1970 - sent) * 1000, Int(first.origin),
                                 String(change.split(separator: " ").last ?? "?")))
        } else {
            report.append("Mac-side change: no notification seen (Mac side: \(change))")
        }
        XCTAssertTrue(gotIt, "a change made on the Mac did not reach the iOS client")
        XCTAssertTrue(change.hasSuffix("ok"), "Mac-side change: \(change)")

        // Restore-verified writes through the hub.
        guard let backup = env["DSPI_LINK_BACKUP_DIR"] else {
            report.append("writes: skipped (no DSPI_LINK_BACKUP_DIR)")
            return
        }
        let writes = RestoreVerifiedWrites(transport: composite)
        let token = writes.observe()
        let failure = try writes.run(referenceDirectory: backup)
        token.cancel()
        report.append("writes:")
        report.append(contentsOf: writes.report)
        if let f = failure { XCTFail(f) }
    }
}
#endif
