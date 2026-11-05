import XCTest
import Combine
@testable import DSPi_Console

/// MIDITransport against a fake MIDI port and device (MIDITestSupport.swift):
/// connect, ordering, tag correlation, timeouts, retries, notifications,
/// hot-plug and read-only mode.  The write paths are exercised here only;
/// they are never sent to a real unit.
final class MIDITransportTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func connected(_ device: FakeMIDIDevice = FakeMIDIDevice(), readOnly: Bool = false,
                           file: StaticString = #filePath, line: UInt = #line) -> (MIDITransport, FakeMIDIControlPort) {
        let port = FakeMIDIControlPort(device: device)
        let midi = MIDITransport(port: port, autoSelect: true, readOnly: readOnly, requestTimeout: 0.5, bulkTimeout: 1)
        XCTAssertTrue(spinUntil { midi.isConnected }, "never connected", file: file, line: line)
        return (midi, port)
    }

    private func get(_ midi: MIDITransport, _ request: UInt8, value: UInt16 = 0, index: UInt16 = 2,
                     length: UInt16 = 4) -> Result<Data, LinkStatus> {
        midi.getControlResult(request: request, value: value, index: index, length: length)
    }

    // MARK: - Connect

    func testConnectProbesPlatformFirst() {
        let (midi, port) = connected()
        XCTAssertEqual(midi.availableDevices.map(\.serial), [FakeMIDIControlPort.endpoint.serial])
        XCTAssertEqual(midi.selectedDevice?.serial, FakeMIDIControlPort.endpoint.serial)
        XCTAssertEqual(midi.selectedDevice?.locationID, FakeMIDIControlPort.endpoint.locationID)
        XCTAssertNil(midi.errorMessage)
        let first = port.device.requests.first
        XCTAssertEqual(first?.frame.type, MIDIControlCodec.typeGet)
        XCTAssertEqual(first?.frame.request, REQ_GET_PLATFORM)
        XCTAssertEqual(port.device.requests.count, 1, "nothing else before the view model asks")
    }

    func testReselectingTheOpenDeviceKeepsThePort() {
        let port = FakeMIDIControlPort()
        let midi = MIDITransport(port: port, autoSelect: true, readOnly: false, requestTimeout: 0.5)
        midi.selectDevice(midi.availableDevices[0])               // while the probe is in flight
        XCTAssertTrue(spinUntil { midi.isConnected })
        midi.selectDevice(midi.availableDevices[0])
        XCTAssertEqual(port.openCount, 1)
        XCTAssertEqual(port.device.requests.count, 1)
        XCTAssertEqual(midi.stats.staleReplies, 0)
        midi.reconnect()                                           // forces a reopen
        XCTAssertTrue(spinUntil { midi.isConnected && port.openCount == 2 })
    }

    func testSilentPortNeverConnects() {
        let device = FakeMIDIDevice { _ in nil }
        let port = FakeMIDIControlPort(device: device)
        let midi = MIDITransport(port: port, autoSelect: true, readOnly: false, requestTimeout: 0.1)
        XCTAssertTrue(spinUntil { midi.errorMessage != nil })
        XCTAssertFalse(midi.isConnected)
        XCTAssertEqual(device.requests.count, 3, "three platform probes")
    }

    func testNoDeviceWhenNothingIsOpen() {
        let port = FakeMIDIControlPort(endpoints: [])
        let midi = MIDITransport(port: port, autoSelect: true, readOnly: false)
        XCTAssertEqual(get(midi, REQ_GET_PLATFORM), .failure(.noDevice))
        XCTAssertNil(midi.selectedDevice)
    }

    // MARK: - Requests

    func testSetThenGetKeepOrderAndRoundTrip() throws {
        let (midi, port) = connected()
        let volume = Data([0x00, 0x00, 0x20, 0xC1])               // -10 dB
        midi.sendControlRequest(request: 0xD2, value: 0, index: 2, data: volume)
        XCTAssertEqual(try get(midi, 0xD3).get(), volume)
        let kinds = port.device.requests.dropFirst().map { $0.frame.request }
        XCTAssertEqual(kinds, [0xD2, 0xD3])
        let set = try XCTUnwrap(port.device.requests.dropFirst().first?.frame)
        XCTAssertEqual(set.type, MIDIControlCodec.typeSet)
        XCTAssertEqual(set.length, 4)
        XCTAssertEqual(set.index, 2)
        XCTAssertEqual(set.payload, [UInt8](volume))
    }

    func testTagsRotateAndSkipReservedValues() {
        let (midi, port) = connected()
        for _ in 0..<300 { _ = get(midi, 0xD3) }
        let tags = port.device.requests.map(\.tag)
        XCTAssertFalse(tags.contains(0))
        XCTAssertFalse(tags.contains(0x7F))
        XCTAssertEqual(Set(tags).count, 0x7E)
        for (a, b) in zip(tags, tags.dropFirst()) { XCTAssertNotEqual(a, b) }
        XCTAssertEqual(midi.stats.timeouts, 0)
    }

    func testBulkReadArrivesWhole() throws {
        let (midi, _) = connected()
        let bulk = try get(midi, REQ_GET_ALL_PARAMS, length: UInt16(6136)).get()
        XCTAssertEqual([UInt8](bulk), FakeMIDIDevice.bulkImage)
        XCTAssertEqual(midi.stats.bulkReads.count, 1)
        XCTAssertEqual(midi.stats.bulkReads.first?.bytes, 6136)
    }

    func testBulkWriteIsOneMessage() throws {
        let (midi, port) = connected()
        midi.sendControlRequest(request: REQ_SET_ALL_PARAMS, value: 0, index: 2, data: Data(FakeMIDIDevice.bulkImage))
        _ = get(midi, 0xD3)                                         // waits behind the SET
        let set = try XCTUnwrap(port.device.requests.first { $0.frame.request == REQ_SET_ALL_PARAMS }?.frame)
        XCTAssertEqual(set.payload, FakeMIDIDevice.bulkImage)
        XCTAssertEqual(set.length, 6136)
    }

    func testDeviceStatusesMapToLinkStatus() {
        let (midi, port) = connected()
        XCTAssertEqual(get(midi, 0x99), .failure(.error), "refused request")
        port.device.unknownTagError = true
        XCTAssertEqual(get(midi, 0xD3), .failure(.frameError), "tag 0x7F answers the request in flight")
        XCTAssertNoThrow(try get(midi, 0xD3).get())
    }

    func testBusyIsRetried() throws {
        let (midi, port) = connected()
        port.device.busyReplies = 2
        XCTAssertNoThrow(try get(midi, 0xD3).get())
        XCTAssertEqual(midi.stats.retries, 2)
        port.device.busyReplies = MIDITransport.maxRetries + 1
        XCTAssertEqual(get(midi, 0xD3), .failure(.busy))
    }

    func testTimeoutAndLateReplyDoNotConfuseTheNextRequest() throws {
        let (midi, port) = connected()
        port.device.droppedReplies = 1
        XCTAssertEqual(get(midi, 0xD3), .failure(.timeout))
        // A reply that comes after the transport gave up carries the old tag.
        port.device.delayNextReply = 0.7
        XCTAssertEqual(get(midi, REQ_GET_PLATFORM, length: 7), .failure(.timeout))
        Thread.sleep(forTimeInterval: 0.4)                          // the late reply lands now
        XCTAssertEqual(try get(midi, 0xD3).get(), Data([0, 0, 0xA0, 0xC1]))
        XCTAssertGreaterThanOrEqual(midi.stats.staleReplies, 1)
        XCTAssertTrue(midi.isConnected, "two timeouts are not a dead link")
    }

    func testStaleReplyBeforeTheRealOneIsIgnored() throws {
        let (midi, port) = connected()
        port.device.staleReplyFirst = true
        XCTAssertEqual(try get(midi, 0xD3).get(), Data([0, 0, 0xA0, 0xC1]))
        XCTAssertEqual(midi.stats.staleReplies, 1)
    }

    func testThreeTimeoutsInARowDisconnect() {
        let (midi, port) = connected()
        midi.requestTimeout = 0.1
        port.device.droppedReplies = 3
        for _ in 0..<3 { XCTAssertEqual(get(midi, 0xD3), .failure(.timeout)) }
        XCTAssertTrue(spinUntil { !midi.isConnected })
        XCTAssertNotNil(midi.errorMessage)
    }

    func testForeignAndBrokenSysExAreIgnored() throws {
        let (midi, port) = connected()
        port.device.sendRaw([0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0xF7])          // identity reply
        port.device.sendRaw([0xF0, 0x7D, 0x44, 0x53, 0x50, 0x02, 0x01, 0xF7])    // our ID, wrong version
        XCTAssertEqual(try get(midi, 0xD3).get(), Data([0, 0, 0xA0, 0xC1]))
        XCTAssertTrue(spinUntil { midi.stats.foreignSysEx == 1 && midi.stats.malformed == 1 })
    }

    // MARK: - Notifications

    func testNotificationsReachObserversWithOrigin() {
        let (midi, port) = connected()
        var received: [LinkNotification] = []
        midi.addNotificationObserver { received.append($0) }.store(in: &cancellables)
        port.device.notify(FakeMIDIDevice.paramChanged(seq: 10, source: 7))       // OS volume slider
        port.device.notify(FakeMIDIDevice.paramChanged(seq: 11, source: MIDITransport.paramSourceMIDI))
        XCTAssertTrue(spinUntil { received.count == 2 })
        XCTAssertEqual(received.map(\.eventID), [0x02, 0x02])
        XCTAssertEqual(received[0].origin, 0)
        XCTAssertFalse(midi.isOwnWrite(origin: received[0].origin))
        XCTAssertEqual(received[1].origin, midi.session)
        XCTAssertTrue(midi.isOwnWrite(origin: received[1].origin), "our own echo")
        XCTAssertEqual(received[0].packet, Data(FakeMIDIDevice.paramChanged(seq: 10, source: 7)))
    }

    func testSequenceGapAsksForAResync() {
        let (midi, port) = connected()
        var events: [UInt8] = []
        midi.addNotificationObserver { events.append($0.eventID) }.store(in: &cancellables)
        port.device.notify(FakeMIDIDevice.paramChanged(seq: 255, source: 7))
        port.device.notify(FakeMIDIDevice.paramChanged(seq: 0, source: 7))     // wraps, no gap
        port.device.notify(FakeMIDIDevice.paramChanged(seq: 3, source: 7))     // 1 and 2 lost
        XCTAssertTrue(spinUntil { events.count == 4 })
        XCTAssertEqual(events, [0x02, 0x02, 0x02, 0x03])
        XCTAssertEqual(midi.stats.sequenceGaps, 1)
    }

    func testNotificationBetweenRequestAndReplyIsDelivered() throws {
        let device = FakeMIDIDevice()
        let simple = FakeMIDIDevice.simpleModel()
        device.respond = { [weak device] r in
            if r.request == 0xD3 { device?.notify(FakeMIDIDevice.paramChanged(seq: 1, source: 5)) }
            return simple(r)
        }
        let (midi, _) = connected(device)
        var count = 0
        midi.addNotificationObserver { _ in count += 1 }.store(in: &cancellables)
        XCTAssertEqual(try get(midi, 0xD3).get(), Data([0, 0, 0xA0, 0xC1]))
        XCTAssertTrue(spinUntil { count == 1 })
    }

    // MARK: - Hot-plug

    func testUnplugAndReplug() {
        let (midi, port) = connected()
        let generation = midi.generation
        port.setEndpoints([])
        XCTAssertTrue(spinUntil { !midi.isConnected && midi.selectedDevice == nil })
        XCTAssertEqual(midi.availableDevices, [])
        XCTAssertNil(port.openEndpoint)
        XCTAssertEqual(get(midi, 0xD3), .failure(.noDevice))

        port.setEndpoints([FakeMIDIControlPort.endpoint])
        XCTAssertTrue(spinUntil { midi.isConnected })
        XCTAssertGreaterThan(midi.generation, generation)
        XCTAssertNoThrow(try get(midi, 0xD3).get())
    }

    func testUserDisconnectStaysDisconnectedUntilAPlugEvent() {
        let (midi, port) = connected()
        midi.disconnect()
        XCTAssertFalse(midi.isConnected)
        port.setEndpoints([FakeMIDIControlPort.endpoint])          // same list, nothing new
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(midi.selectedDevice)
        midi.selectDevice(midi.availableDevices[0])
        XCTAssertTrue(spinUntil { midi.isConnected })
    }

    // MARK: - Read-only

    func testReadOnlyRefusesWritesLocally() {
        let (midi, port) = connected(readOnly: true)
        midi.sendControlRequest(request: 0xD2, value: 0, index: 2, data: Data([0, 0, 0, 0]))
        XCTAssertEqual(get(midi, 0x90), .failure(.denied), "preset save is write-as-read")
        XCTAssertEqual(get(midi, REQ_ENTER_BOOTLOADER_FOR_TEST), .failure(.denied))
        XCTAssertNoThrow(try get(midi, 0xD3).get())
        XCTAssertEqual(port.device.requests.map { $0.frame.request }, [REQ_GET_PLATFORM, 0xD3])
        XCTAssertEqual(midi.stats.refusedReadOnly, 3)
    }

    func testReadOnlyAllowListHasOnlyGetters() {
        // Every write-as-read request of the firmware's command table.
        let writeAsRead: Set<UInt8> = [0x51, 0x52, 0x53, 0x7C, 0x83, 0x90, 0x91, 0x92, 0xB1, 0xB3,
                                       0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xD6, 0xE4, 0xEC, 0xF0, 0xF1]
        XCTAssertTrue(MIDITransport.pureReads.isDisjoint(with: writeAsRead))
        XCTAssertTrue(MIDITransport.pureReads.isDisjoint(with: [0x0E, 0xA6, 0xA1, 0xA3, 0xF5, 0xF7]))
        for r in [REQ_GET_PLATFORM, REQ_GET_ALL_PARAMS, REQ_GET_STATUS, REQ_GET_MASTER_VOLUME] {
            XCTAssertTrue(MIDITransport.pureReads.contains(r))
        }
    }

    // MARK: - The console over MIDI

    /// The demo device's state served through the MIDI codec: the view
    /// model's whole connect-time read decodes as it does on the demo device.
    func testFetchAllOverMIDIDecodesTheCapture() throws {
        let fake = FakeTransport(autoSelect: false)
        fake.selectDevice(FakeTransport.demoDevice)
        let device = FakeMIDIDevice.backed(by: fake)
        let port = FakeMIDIControlPort(device: device)
        let midi = MIDITransport(port: port, autoSelect: false, readOnly: false)
        let vm = DSPViewModel(transport: midi)
        midi.selectDevice(midi.availableDevices[0])
        XCTAssertTrue(spinUntil { midi.isConnected })

        let fetched = expectation(description: "fetchAll")
        DispatchQueue.global().async {
            vm.fetchAll()
            DispatchQueue.main.async { fetched.fulfill() }
        }
        wait(for: [fetched], timeout: 60)

        XCTAssertEqual(vm.platformName, "RP2350")
        XCTAssertEqual(vm.outputEnabled, [true, true, false, false, false, false, false, false, false])
        XCTAssertEqual(vm.masterVolumeDB, -20)
        XCTAssertEqual(Array(vm.channelNames.prefix(2)), ["USB 1", "USB 2"])
        XCTAssertTrue(vm.matrixRouting[0][0])
        XCTAssertTrue(vm.lgSoundSyncEnabled)
        XCTAssertGreaterThanOrEqual(midi.stats.bulkReads.count, 1)
        XCTAssertEqual(midi.stats.timeouts, 0)
        XCTAssertEqual(midi.stats.staleReplies, 0)

        // A write from the console reaches the demo device and its echo is
        // attributed by source byte (HOST_SET from the fake, so not ours).
        var notes: [LinkNotification] = []
        midi.addNotificationObserver { notes.append($0) }.store(in: &cancellables)
        midi.sendControlRequest(request: REQ_SET_MASTER_VOLUME_FOR_TEST, value: 0, index: 2,
                                data: withUnsafeBytes(of: Float(-30)) { Data($0) })
        XCTAssertTrue(spinUntil { !notes.isEmpty })
        let readBack = try get(midi, REQ_GET_MASTER_VOLUME).get()
        XCTAssertEqual(readBack.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, -30)
    }
}

private let REQ_ENTER_BOOTLOADER_FOR_TEST: UInt8 = 0xF0
private let REQ_SET_MASTER_VOLUME_FOR_TEST: UInt8 = 0xD2
