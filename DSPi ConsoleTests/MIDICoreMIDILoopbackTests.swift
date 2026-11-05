import XCTest
import CoreMIDI
@testable import DSPi_Console

/// The real CoreMIDI path (`CoreMIDIControlPort`: discovery, MIDISendEventList,
/// the UMP input port) against a fake DSPi made of a virtual source and a
/// virtual destination in this process, so the write paths and the 7 KB
/// messages cross CoreMIDI without a device.  macOS needs a logged-in GUI
/// session for CoreMIDI; iOS refuses virtual endpoints to apps without the
/// audio background mode, so there the test skips.
final class MIDICoreMIDILoopbackTests: XCTestCase {

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    override func tearDown() {
        if source != 0 { MIDIEndpointDispose(source) }
        if destination != 0 { MIDIEndpointDispose(destination) }
        if client != 0 { MIDIClientDispose(client) }
        super.tearDown()
    }

    func testRequestsCrossCoreMIDI() throws {
        guard MIDIClientCreateWithBlock("DSPi loopback device" as CFString, &client, nil) == noErr else {
            throw XCTSkip("No CoreMIDI client (no GUI session?)")
        }
        let name = "DSPi Loopback Test \(UUID().uuidString.prefix(6))"
        let device = FakeMIDIDevice()
        var status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        if status == kMIDINotPermitted { throw XCTSkip("Virtual MIDI endpoints are not permitted here") }
        XCTAssertEqual(status, noErr)
        status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &destination) { list, _ in
            for packet in list.unsafeSequence() {
                device.receive(CoreMIDIControlPort.words(of: packet))
            }
        }
        if status == kMIDINotPermitted { throw XCTSkip("Virtual MIDI endpoints are not permitted here") }
        XCTAssertEqual(status, noErr)
        let src = source
        device.emit = { words in
            _ = CoreMIDIControlPort.withEventList(words) { MIDIReceivedEventList(src, $0) }
        }

        let port = CoreMIDIControlPort(clientName: "DSPi loopback host", extraName: name)
        XCTAssertNil(port.unavailableReason)
        XCTAssertTrue(spinUntil { port.endpoints.contains { $0.name.contains(name) } }, "virtual DSPi not discovered")
        let endpoint = try XCTUnwrap(port.endpoints.first { $0.name.contains(name) })
        XCTAssertTrue(endpoint.serial.hasPrefix("MIDI-"), "no USB serial on a virtual endpoint")

        let midi = MIDITransport(port: port, autoSelect: false, readOnly: false)
        let dspi = try XCTUnwrap(midi.availableDevices.first { $0.serial == endpoint.serial })
        midi.selectDevice(dspi)
        XCTAssertTrue(spinUntil { midi.isConnected }, "platform probe did not cross CoreMIDI")

        // Small SET then GET, in order.
        let volume = Data([0, 0, 0x70, 0xC1])
        midi.sendControlRequest(request: 0xD2, value: 0, index: 2, data: volume)
        XCTAssertEqual(try midi.getControlResult(request: 0xD3, value: 0, index: 2, length: 4).get(), volume)

        // The two 7 KB messages, both ways.
        let started = Date()
        let bulk = try midi.getControlResult(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: 6136).get()
        let readTime = Date().timeIntervalSince(started)
        XCTAssertEqual([UInt8](bulk), FakeMIDIDevice.bulkImage)
        let image = FakeMIDIDevice.bulkImage.reversed().map { $0 }
        midi.sendControlRequest(request: REQ_SET_ALL_PARAMS, value: 0, index: 2, data: Data(image))
        _ = midi.getControlResult(request: 0xD3, value: 0, index: 2, length: 4)
        XCTAssertEqual(device.requests.first { $0.frame.request == REQ_SET_ALL_PARAMS }?.frame.payload, image)

        // A notification.
        var notes = 0
        let token = midi.addNotificationObserver { _ in notes += 1 }
        device.notify(FakeMIDIDevice.paramChanged(seq: 1, source: 7))
        XCTAssertTrue(spinUntil { notes == 1 })
        token.cancel()

        XCTAssertEqual(midi.stats.timeouts, 0)
        XCTAssertEqual(midi.stats.malformed, 0)
        print("CoreMIDI loopback: 0xA0 6136 B in \(String(format: "%.1f", readTime * 1000)) ms\n\(midi.statsSummary())")
    }
}
