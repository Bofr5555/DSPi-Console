import XCTest

/// The iOS console driven with touch in the Simulator, on the demo device
/// (A3): the one-pane layout's channel list and the on-graph PEQ editor.
/// Uses the launch hooks of IOSApp.swift; `-DemoPreset 2` gives USB 1 four
/// bands (low shelf 80 Hz, bells at 250 Hz and 3150 Hz, high shelf 10 kHz).
final class ConsoleTouchUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LocalTransport", "demo", "-DemoMode", "YES", "-DemoPreset", "2"] + args
        app.launch()
        return app
    }

    private func dots(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Band '"))
    }

    private func dot(_ app: XCUIApplication, _ band: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Band \(band),")).firstMatch
    }

    /// The gain in a dot's accessibility value ("250 Hz, -2.5 dB, Q 1.200").
    private func gain(_ element: XCUIElement) -> Double? {
        guard let value = element.value as? String else { return nil }
        let parts = value.components(separatedBy: ", ")
        guard parts.count >= 2 else { return nil }
        return Double(parts[1].replacingOccurrences(of: " dB", with: "").replacingOccurrences(of: "+", with: ""))
    }

    func testDraggingABellUpRaisesItsGain() throws {
        let app = launch(["-SelectChannel", "in1"])
        let bell = dot(app, 2)
        XCTAssertTrue(bell.waitForExistence(timeout: 30), "no band dots on the channel page")
        let before = try XCTUnwrap(gain(bell))
        let start = bell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -40)))
        let after = try XCTUnwrap(gain(dot(app, 2)))
        XCTAssertGreaterThan(after, before + 2, "gain \(before) -> \(after)")
    }

    /// The Q in a dot's accessibility value.
    private func q(_ element: XCUIElement) -> Double? {
        guard let value = element.value as? String, let range = value.range(of: "Q ") else { return nil }
        return Double(value[range.upperBound...])
    }

    func testPinchChangesTheSelectedBandsQ() throws {
        let app = launch(["-SelectChannel", "in1", "-SelectBand", "2"])
        let bell = dot(app, 2)
        XCTAssertTrue(bell.waitForExistence(timeout: 30))
        let before = try XCTUnwrap(q(bell))
        let graph = app.otherElements["Response graph"]
        XCTAssertTrue(graph.exists)
        graph.pinch(withScale: 2, velocity: 1)
        let after = try XCTUnwrap(q(dot(app, 2)))
        XCTAssertGreaterThan(after, before * 1.3, "Q \(before) -> \(after)")
    }

    func testDoubleTapAddsABandAndLongPressDeletesIt() throws {
        let app = launch(["-SelectChannel", "in1"])
        XCTAssertTrue(dot(app, 1).waitForExistence(timeout: 30))
        XCTAssertEqual(dots(app).count, 4)
        // Empty graph well below the 250 Hz bell.
        let empty = dot(app, 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 40, dy: 70))
        empty.doubleTap()
        XCTAssertTrue(dot(app, 5).waitForExistence(timeout: 5), "double-tap did not add band 5")
        dot(app, 5).press(forDuration: 1.0)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no band menu on long press")
        delete.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: dot(app, 5))
        waitForExpectations(timeout: 5)
        XCTAssertEqual(dots(app).count, 4)
    }

    /// iPhone only: one pane at a time; the channel list comes from the
    /// toolbar, and picking a channel goes back to the console with its page.
    func testChannelListOnAPhone() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("one-pane layout test for iPhone") }
        let app = launch([])
        let channels = app.buttons["Channels"]
        XCTAssertTrue(channels.waitForExistence(timeout: 30))
        channels.tap()
        XCTAssertTrue(app.buttons["Console"].waitForExistence(timeout: 5))
        let usb1 = app.staticTexts["USB 1"].firstMatch
        XCTAssertTrue(usb1.waitForExistence(timeout: 5))
        usb1.tap()
        XCTAssertTrue(app.buttons["Channels"].waitForExistence(timeout: 5), "picking a channel did not show the console")
        XCTAssertTrue(dot(app, 1).waitForExistence(timeout: 10), "channel page with its graph dots")
    }
}
