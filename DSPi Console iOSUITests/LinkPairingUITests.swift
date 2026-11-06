import XCTest

/// Pairing with a real DSPi Link hub through the app's UI: Devices sheet,
/// look for hubs, pick the hub's device, type the PIN into the pairing
/// sheet.  Opt-in: DSPI_LINK_HW=1 with LinkHubHarnessTests running on the
/// Mac, which publishes the PIN in DSPI_LINK_DIR/hub.txt.
final class LinkPairingUITests: XCTestCase {

    func testPairFromTheDevicesSheet() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DSPI_LINK_HW"] == "1" else { throw XCTSkip("Set DSPI_LINK_HW=1 with a hub running") }
        let dir = env["DSPI_LINK_DIR"] ?? "/Users/user/probe/link"
        let text = try String(contentsOfFile: dir + "/hub.txt", encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let pin = lines[0], hubName = lines[2]
        XCTAssertEqual(pin.count, 6, "no pairing window open on the hub")

        let app = XCUIApplication()
        app.launchArguments = ["-LocalTransport", "demo", "-DemoMode", "NO"]
        app.launch()

        let devicesButton = app.buttons["Devices"]
        XCTAssertTrue(devicesButton.waitForExistence(timeout: 30))
        devicesButton.tap()

        let look = app.switches["Look for hubs on this network"]
        XCTAssertTrue(look.waitForExistence(timeout: 10))
        if (look.value as? String) != "1" { look.switches.firstMatch.tap() }

        // The hub's device, found by Bonjour: "<name> via <hub name>".  If
        // Bonjour finds nothing (the hub may not be allowed to advertise),
        // type its address, as a user would.
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "via \(hubName)")).firstMatch
        if !row.waitForExistence(timeout: 20) {
            let address = app.textFields["Hub address (host or host:port)"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.tap()
            address.typeText("127.0.0.1:\(lines[1])\n")
            print("LinkPairingUITests: not found by Bonjour, typed 127.0.0.1:\(lines[1])")
        } else {
            // Found by Bonjour, or a typed address saved by an earlier run.
            print("LinkPairingUITests: listed without typing")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the hub's device was not listed")
        row.tap()

        let field = app.textFields["Pairing code"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no pairing sheet")
        field.tap()
        field.typeText(pin)
        app.buttons["Pair"].tap()

        // Connected: the sheet is gone and the device row is the selected one.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: field)
        waitForExpectations(timeout: 20)
        app.buttons["Done"].firstMatch.tap()
        let status = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "via \(hubName)")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 30), "the console does not show the hub's device")
    }
}
