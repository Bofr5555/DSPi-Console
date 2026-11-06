import XCTest
import Combine
@testable import DSPi_Console

/// The DSPi Link client pieces the iOS app adds (A7): the non-blocking
/// pairing prompt, and a DSPi on USB MIDI beside DSPi Link hubs in one device
/// list.  Platform-neutral, so they run in both test targets.
final class LinkClientIOSTests: XCTestCase {

    private func make() -> (NetworkTransport, LinkClientFake, LinkTokenStore) {
        let client = LinkClientFake()
        let tokens = LinkTokenStore(service: "test-\(UUID().uuidString)")
        let t = NetworkTransport(client: client, hubID: "hub-1", hubName: "Studio",
                                 tokens: tokens, clientName: "Test")
        return (t, client, tokens)
    }

    private let url = URL(string: "ws://10.0.0.2:11915/dspi/v1")!

    // MARK: - Async pairing

    func testAsyncPromptPairsWhenAnswered() {
        let (t, client, tokens) = make()
        var asked: [String] = []
        var answer: ((String?) -> Void)?
        t.asyncPairingPrompt = { name, done in asked.append(name); answer = done }
        t.connect(to: url)
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(asked, ["Studio"])
        XCTAssertEqual(client.pairCalls, [], "nothing sent before the user answers")

        answer?("123456")
        XCTAssertEqual(client.pairCalls, ["123456"])
        XCTAssertEqual(tokens.token(forHub: "hub-1"), "tok-abc")
        XCTAssertEqual(t.session, 7)
        tokens.removeToken(forHub: "hub-1")
    }

    func testAsyncPromptIsPreferredOverTheModalOne() {
        let (t, client, _) = make()
        var modal = 0, sheet = 0
        t.pairingPrompt = { _ in modal += 1; return "111111" }
        t.asyncPairingPrompt = { _, done in sheet += 1; done("222222") }
        t.connect(to: url)
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(modal, 0)
        XCTAssertEqual(sheet, 1)
        XCTAssertEqual(client.pairCalls, ["222222"])
    }

    func testCancellingTheSheetGivesTheConnectionUp() {
        let (t, client, _) = make()
        t.asyncPairingPrompt = { _, done in done(nil) }
        t.connect(to: url)
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(client.disconnectCalls, 1)
        XCTAssertEqual(client.pairCalls, [])
    }

    func testOneSheetAtATimeAcrossReconnects() {
        let (t, client, _) = make()
        var asks = 0
        var answer: ((String?) -> Void)?
        t.asyncPairingPrompt = { _, done in asks += 1; answer = done }
        t.connect(to: url)
        client.setState(.awaitingAuth(needsPairing: true))
        // The hub's auth deadline closes the socket while the sheet is up,
        // and the reconnect asks again: still one sheet.
        client.setState(.failed("authentication timed out"))
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(asks, 1)
        answer?("123456")
        XCTAssertEqual(client.pairCalls, ["123456"])
    }

    func testAPINTypedAfterTheSocketClosedWaitsForTheNextConnection() {
        let (t, client, _) = make()
        var answer: ((String?) -> Void)?
        t.asyncPairingPrompt = { _, done in answer = done }
        t.connect(to: url)
        client.setState(.awaitingAuth(needsPairing: true))
        client.setState(.failed("authentication timed out"))
        answer?("123456")
        XCTAssertEqual(client.pairCalls, [], "no session to pair on yet")
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(client.pairCalls, ["123456"])
    }

    func testAWrongPINAsksAgain() {
        let (t, client, _) = make()
        var asks = 0
        client.pairResult = .failure(.rejected(code: "bad_pin", message: nil))
        t.asyncPairingPrompt = { _, done in
            asks += 1
            if asks == 2 { client.pairResult = .success("tok-abc") }
            done(asks == 1 ? "000000" : "123456")
        }
        t.connect(to: url)
        client.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(asks, 2)
        XCTAssertEqual(client.pairCalls, ["000000", "123456"])
    }

    func testTheCompositeHandsItsAsyncPromptToEachHub() throws {
        let fake = LinkClientFake()
        let composite = CompositeTransport(local: FakeTransport(autoSelect: false),
                                           tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { fake }
        var asked: [String] = []
        composite.asyncPairingPrompt = { name, _ in asked.append(name) }
        composite.updateHubs([hub("hub-1", serials: ["REMOTE0000REMOTE"])])
        let remote = try XCTUnwrap(composite.availableDevices.first { $0.isRemote })
        composite.selectDevice(remote)
        fake.setState(.awaitingAuth(needsPairing: true))
        XCTAssertEqual(asked, ["Studio"])
    }

    // MARK: - USB MIDI and DSPi Link in one list

    private func hub(_ id: String, serials: [String]) -> DiscoveredHub {
        DiscoveredHub(id: id, name: "Studio", kind: "console", authMode: "pin",
                      deviceCount: serials.count, serials: serials, path: "/dspi/v1",
                      tls: false, host: "10.0.0.2", port: 11915, isManual: false)
    }

    /// The same board on USB MIDI and shared by a Mac hub is listed once, as
    /// the local device: the composite keys devices on serial and lists local
    /// devices first (spec 3.1), and MIDI reports the board's USB serial.
    func testABoardOnMIDIAndOnAHubIsListedOnceAsLocal() {
        let port = FakeMIDIControlPort()
        let midi = MIDITransport(port: port, autoSelect: false, readOnly: true)
        let local = LocalTransportSet([midi, FakeTransport(autoSelect: false)])
        let composite = CompositeTransport(local: local, tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { LinkClientFake() }
        let serial = FakeMIDIControlPort.endpoint.serial
        composite.updateHubs([hub("hub-1", serials: [serial, "OTHERBOARD000001"])])

        let devices = composite.availableDevices
        XCTAssertEqual(devices.filter { $0.serial == serial }.count, 1, "one entry per board")
        XCTAssertEqual(devices.first { $0.serial == serial }?.isRemote, false, "the local path wins")
        XCTAssertTrue(devices.contains { $0.serial == "OTHERBOARD000001" && $0.isRemote })
        XCTAssertTrue(devices.contains { $0 == FakeTransport.demoDevice })

        // Picking it goes to MIDI, not to the hub.
        composite.selectDevice(devices.first { $0.serial == serial }!)
        XCTAssertTrue(spinUntil { midi.isConnected })
        XCTAssertFalse(composite.isRemoteActive)
    }

    #if os(iOS)
    func testPairingCodesAreSixDigits() {
        XCTAssertTrue(IOSLinkPairing.isValid("012345"))
        XCTAssertFalse(IOSLinkPairing.isValid("12345"))
        XCTAssertFalse(IOSLinkPairing.isValid("1234567"))
        XCTAssertFalse(IOSLinkPairing.isValid("12a456"))
    }
    #endif
}
