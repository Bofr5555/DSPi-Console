#if os(macOS)
import XCTest
import AppKit
@testable import DSPi_Console

/// The Mac side of the DSPi Link hardware run: the host app shares its DSPi
/// as a DSPi Link hub (gateway mode, PIN pairing) for a while, so an iOS
/// Simulator client can discover, pair, read and write (LinkHardwareTests,
/// LinkPairingUITests).  Opt-in: DSPI_LINK_HUB=1 (`TEST_RUNNER_DSPI_LINK_HUB=1`).
///
/// The hub's device leg: the USB vendor path normally, or with
/// DSPI_LINK_HUB_VIA_MIDI=1 (host app on `LocalTransport` midi) the app's
/// MIDITransport behind a HubDevice.  The second exists for the macOS VM,
/// whose USB pass-through refuses control transfers over 4096 bytes, so the
/// vendor path's 6136-byte REQ_GET_ALL_PARAMS fails there and the Console
/// drops the board.  Everything from the hub to the client is the same.
///
/// It talks to the client side through files in DSPI_LINK_DIR (default
/// ~/probe/link):
///   hub.txt     written here: PIN, port, hub name, hub id (one per line)
///   cmd         written by the client side, removed when handled:
///                 pin     open a new pairing window (hub.txt rewritten)
///                 change  a change made on the Mac, for the client to see:
///                         channel 8's name set and restored, verified;
///                         change.txt gets the send time and the result
///                 stop    end the run
///
/// On the way out it stops sharing, revokes the clients paired during the
/// run and puts the access mode back, so the Mac's settings are as before.
final class LinkHubHarnessTests: XCTestCase {

    @MainActor
    func testShareTheUSBDeviceAsAHub() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DSPI_LINK_HUB"] == "1" else { throw XCTSkip("Set DSPI_LINK_HUB=1 to share the DSPi as a hub") }
        let viaMIDI = env["DSPI_LINK_HUB_VIA_MIDI"] == "1"
        guard viaMIDI == AppState.usesMIDITransport else {
            throw XCTSkip("Host app's LocalTransport does not match DSPI_LINK_HUB_VIA_MIDI")
        }
        let dir = env["DSPI_LINK_DIR"] ?? (NSHomeDirectory() + "/probe/link")
        let seconds = Double(env["DSPI_LINK_HUB_SECONDS"] ?? "900") ?? 900
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // No window: in the VM the paravirtual GPU has panicked with the
        // Console's Metal views and the Simulator rendering at once, and a
        // hub needs no UI.  Hidden windows stop their spectrum surfaces.
        if env["DSPI_LINK_HUB_SHOW_UI"] != "1" {
            NSApp.windows.forEach { $0.orderOut(nil) }
            NSApp.hide(nil)
        }

        let local = AppState.shared.localTransport
        _ = AppState.shared.transport
        var forwarding: Any?
        if viaMIDI {
            let hub = AppState.shared.linkHub
            hub.usbDeviceFactory = { _ in nil }             // the USB path never attaches
            if hub.isDeviceAttached { hub.detachDevice() }
            let midi = AppState.shared.midiTransport
            guard spinUntil(30, { midi.isConnected }) else { throw XCTSkip("No DSPi on MIDI") }
            let device = try XCTUnwrap(MIDIHubDevice(midi: midi), "no platform reply over MIDI")
            hub.attachDevice(device)
            forwarding = midi.addNotificationObserver { note in hub.ingest(MIDIHubDevice.asHostWrite(note)) }
            guard spinUntil(10, { hub.isDeviceAttached }) else { return XCTFail("hub did not attach the MIDI device") }
        } else {
            guard spinUntil(30, { local.isConnected }) else { throw XCTSkip("No DSPi on USB") }
        }
        _ = forwarding
        let changer: any DeviceTransport = viaMIDI ? AppState.shared.midiTransport : local

        let service = AppState.shared.linkService
        let previousMode = service.authMode
        let clientsBefore = Set(service.clients.map(\.id))
        service.authMode = .pin
        service.start()
        XCTAssertTrue(service.isRunning, service.lastError ?? "hub did not start")
        guard service.isRunning else { return }
        defer {
            service.cancelPairing()
            service.stop()
            service.refreshClients()
            for client in service.clients where !clientsBefore.contains(client.id) { service.revoke(client) }
            service.authMode = previousMode
            try? FileManager.default.removeItem(atPath: dir + "/hub.txt")
        }

        func publishPIN() {
            service.allowNewClient()
            let lines = [service.activePIN ?? "", String(LinkDiscovery.defaultPort), service.hubName,
                         AppState.shared.linkHub.auth.hubID.uuidString.lowercased()]
            try? lines.joined(separator: "\n").write(toFile: dir + "/hub.txt", atomically: true, encoding: .utf8)
        }
        publishPIN()
        print("Link hub \(service.hubName) running, PIN in \(dir)/hub.txt")

        let deadline = Date().addingTimeInterval(seconds)
        var lastState = ""
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let state = "usb connected \(AppState.shared.usb.isConnected), hub attached \(AppState.shared.linkHub.isDeviceAttached), " +
                "shared \(AppState.shared.linkHub.sharedDeviceSerials)"
            if state != lastState { print("LinkHub state: \(state)"); lastState = state }
            guard let cmd = try? String(contentsOfFile: dir + "/cmd", encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(atPath: dir + "/cmd")
            switch cmd.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "pin":
                publishPIN()
            case "change":
                let result = macSideChange(changer)
                try? result.write(toFile: dir + "/change.txt", atomically: true, encoding: .utf8)
            case "stop":
                return
            default:
                break
            }
        }
    }

    /// Channel 8's name (channel index 7) set to "Mac side" and restored,
    /// through the Mac's own session on the hub, off the main thread.
    /// Returns "<send time> <ok|failure>".
    @MainActor
    private func macSideChange(_ local: any DeviceTransport) -> String {
        var result = ""
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            guard let original = local.getControlRequest(request: 0x9C, value: 7, index: 2, length: 32) else {
                result = "0 read failed"; return
            }
            var name = Data(count: 32)
            name.replaceSubrange(0..<8, with: Data("Mac side".utf8))
            let sent = Date().timeIntervalSince1970
            local.sendControlRequest(request: 0x9B, value: 7, index: 2, data: name)
            let changed = local.getControlRequest(request: 0x9C, value: 7, index: 2, length: 32)
            Thread.sleep(forTimeInterval: 3)
            local.sendControlRequest(request: 0x9B, value: 7, index: 2, data: original)
            let restored = local.getControlRequest(request: 0x9C, value: 7, index: 2, length: 32)
            let ok = changed?.prefix(8) == Data("Mac side".utf8) && restored == original
            result = String(format: "%.6f %@", sent, ok ? "ok" : "RESTORE-OR-WRITE-FAILED")
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }
}

/// The app's MIDITransport as the hub's device (see the class comment).
final class MIDIHubDevice: HubDevice {
    let midi: MIDITransport
    let info: HubDeviceInfo
    var generation: UInt64 { midi.generation }
    var isConnected: Bool { midi.isConnected }

    init?(midi: MIDITransport) {
        self.midi = midi
        guard case .success(let p) = midi.getControlResult(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 7),
              let reply = FirmwareVersion.fromPlatformReply([UInt8](p)) else { return nil }
        let serial: String
        if case .success(let s) = midi.getControlResult(request: REQ_GET_SERIAL, value: 0, index: 2, length: 16),
           let text = String(data: s.prefix(while: { $0 != 0 }), encoding: .ascii), !text.isEmpty {
            serial = text
        } else {
            serial = midi.selectedDevice?.serial ?? "unknown"
        }
        let v = reply.version
        info = HubDeviceInfo(serial: serial, platform: reply.platform, firmware: "\(v.major).\(v.minor).\(v.patch)",
                             firmwareBeta: p.count >= 7 ? Int(p[p.startIndex + 6]) : nil,
                             outputs: Int(p[p.startIndex + 3]), inputs: nil, wireVersion: nil, link: .usb)
    }

    func execute(_ request: LinkCmdRequest) -> LinkCmdResponse {
        switch request.direction {
        case .get:
            switch midi.getControlResult(request: request.bRequest, value: request.wValue, index: request.wIndex,
                                         length: request.wLength) {
            case .success(let data): return LinkCmdResponse(tag: request.tag, status: .ok, payload: data)
            case .failure(let status): return LinkCmdResponse(tag: request.tag, status: status, payload: Data())
            }
        case .set:
            switch midi.setControlResult(request: request.bRequest, value: request.wValue, index: request.wIndex,
                                         data: request.payload) {
            case .success: return LinkCmdResponse(tag: request.tag, status: .ok, payload: Data())
            case .failure(let status): return LinkCmdResponse(tag: request.tag, status: status, payload: Data())
            }
        }
    }

    /// A change made over MIDI notifies with source PARAM_SRC_MIDI; the hub
    /// attributes only host and bulk writes (sources 1 and 2) to the session
    /// that sent them, which is what its USB device reports.  So a MIDI
    /// source reads as HOST_SET here.
    static func asHostWrite(_ note: LinkNotification) -> LinkNotification {
        var packet = note.packet
        let offset: Int?
        switch note.eventID {
        case 0x02, 0x0C: offset = 8
        case 0x03: offset = 4
        case NOTIFY_EVT_RTA_CONFIG: offset = 16
        case NOTIFY_EVT_INPUT_SOURCE_NAME, NOTIFY_EVT_DEVICE_NAME: offset = 5
        default: offset = nil
        }
        if let o = offset, packet.count > o, packet[packet.startIndex + o] == MIDITransport.paramSourceMIDI {
            packet[packet.startIndex + o] = 1
        }
        return LinkNotification(packet: packet, origin: 0, receivedAt: note.receivedAt)
    }
}
#endif
