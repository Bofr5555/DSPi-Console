import XCTest

/// The extension channel's UI on the demo device, which answers like the bofr
/// firmware: the crossfeed pair editor and the core-voltage status.  Each step
/// leaves a screenshot in the result bundle.
final class ExtensionChannelUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-LocalTransport", "demo", "-DemoMode", "YES", "-DemoPairMap", "k340"] + args
        app.launch()
        return app
    }

    private func keepScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Swipe the sheet up until `element` is on screen.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, tries: Int = 8) {
        var n = 0
        while !element.isHittable && n < tries {
            app.swipeUp()
            n += 1
        }
    }

    func testPairEditorPicksAMapAndValidatesACustomOne() throws {
        let app = launch(["-OpenTool", "crossfeed"])
        let menu = app.buttons["crossfeed.pairs.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no Outputs menu: the probe did not find the pair map")
        scrollTo(menu, in: app)
        XCTAssertTrue(app.buttons["1: Out 3 / Out 1"].exists, "pair chips name the K340 outputs")
        XCTAssertTrue(app.buttons["2: Out 4 / Out 2"].exists)
        keepScreenshot(app, "crossfeed-k340")

        // Back to the default pairing.
        menu.tap()
        app.buttons["Default (1/2, 3/4, …)"].tap()
        XCTAssertTrue(app.buttons["1: Out 1 / Out 2"].waitForExistence(timeout: 5), "the map the device reports")

        // Custom: pair 1 on outputs 1/1 is refused, 1/3 with pair 2 on 4/2 is not.
        menu.tap()
        app.buttons["Custom…"].tap()
        let apply = app.buttons["crossfeed.pairs.editor.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        scrollTo(apply, in: app)
        // Pair 1's right output (the only "Out 2" picker on the default map).
        app.buttons.matching(NSPredicate(format: "label == 'Out 2'")).firstMatch.tap()
        app.buttons["1 — SPDIF 1 L"].tap()
        XCTAssertTrue(app.staticTexts["Each pair needs two different outputs, and no output can be in two pairs."]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(apply.isEnabled)
        keepScreenshot(app, "crossfeed-editor-invalid")

        app.buttons["Cancel"].tap()
        XCTAssertFalse(apply.exists)
        XCTAssertTrue(app.buttons["1: Out 1 / Out 2"].exists, "cancel writes nothing")

        // Swap pair 1's sides: 1/2 -> 2/2 (refused) -> 2/1, applied.
        menu.tap()
        app.buttons["Custom…"].tap()
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        scrollTo(apply, in: app)
        let out = { (label: String) in app.buttons.matching(NSPredicate(format: "label == %@", label)) }
        out("Out 1").firstMatch.tap()
        app.buttons["2 — SPDIF 1 R"].tap()
        XCTAssertFalse(apply.isEnabled, "pair 1 on output 2 twice")
        out("Out 2").element(boundBy: 1).tap()
        app.buttons["1 — SPDIF 1 L"].tap()
        XCTAssertTrue(apply.isEnabled)
        keepScreenshot(app, "crossfeed-editor-valid")
        apply.tap()
        XCTAssertTrue(app.buttons["1: Out 2 / Out 1"].waitForExistence(timeout: 5), "the device took the swapped pair")
        XCTAssertFalse(apply.exists, "the editor closes after Apply")
        keepScreenshot(app, "crossfeed-custom-applied")
    }

    func testOverviewShowsTheCoreVoltage() throws {
        let app = launch(["-OpenTool", "settings", "-SettingsPage", "overview"])
        XCTAssertTrue(app.staticTexts["Core Voltage"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Running at"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1.20 V, raised by the device"].exists)
        XCTAssertTrue(app.staticTexts["1.15 V, hung after 12 min 34 s"].exists)
        keepScreenshot(app, "overview-core-voltage")
    }
}
