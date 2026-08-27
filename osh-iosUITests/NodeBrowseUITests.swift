import XCTest

// MARK: - NodeBrowseUITests
//
// Drives the app against a real node so the Node tab's rendering is checked by
// running it, not by trusting that it compiles. Skipped unless OSH_NODE is set,
// like the other live tests.
//
// Pass the node URL through as TEST_RUNNER_OSH_NODE — xcodebuild does not
// forward the host environment into the simulator process, and strips that
// prefix on the way in.

final class NodeBrowseUITests: XCTestCase {

    private var node: String? {
        let value = ProcessInfo.processInfo.environment["OSH_NODE"]
        return (value?.isEmpty == false) ? value : nil
    }

    @MainActor
    func testBrowsesSystemsOnNode() throws {
        let node = try XCTUnwrap(self.node, "OSH_NODE not set")

        let app = XCUIApplication()
        app.launch()

        // ── add the server ───────────────────────────────────────────────────
        // Six tabs is one more than iPhone shows, so iOS folds the tail into a
        // "More" tab and Settings lives inside it.
        try openTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // The add affordance is a NavigationLink wrapping a plus glyph, so it
        // surfaces under a few different names depending on how SwiftUI chose
        // to label it. Every candidate is existence-checked first: tapping a
        // missing element fails the test outright rather than returning false.
        let candidates: [XCUIElement] = [
            app.buttons["Add"], app.buttons["plus"], app.buttons["Add Server"],
            app.images["plus"], app.cells.buttons.element(boundBy: 0)
        ]
        for candidate in candidates where candidate.exists && candidate.isHittable {
            candidate.tap()
            if app.navigationBars["New Server"].waitForExistence(timeout: 3) { break }
        }

        guard app.navigationBars["New Server"].waitForExistence(timeout: 3) else {
            attach(app.screenshot(), named: "settings-no-add-button")
            XCTFail("could not open the New Server screen; buttons were: "
                    + app.buttons.allElementsBoundByIndex
                        .map { "\($0.identifier)/\($0.label)" }.joined(separator: ", "))
            return
        }

        let label = app.textFields["Label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
        label.typeText("live")

        let url = app.textFields["http://url:port/sensorhub/api"]
        url.tap()
        url.typeText(node)

        // The form requires a username even against a node that allows
        // anonymous access, and this one accepts any credentials while it does.
        let username = app.textFields["Username"]
        username.tap()
        username.typeText("anonymous")

        app.buttons["Save"].tap()
        // Let the save settle before reaching for the tab bar: a tab button
        // underneath a dismissing keyboard reports as present but refuses the
        // accessibility scroll-to-visible action.
        _ = app.navigationBars["Settings"].waitForExistence(timeout: 5)

        // ── browse the node ──────────────────────────────────────────────────
        try openTab("Node", in: app)
        if !app.navigationBars["Node"].waitForExistence(timeout: 8) {
            attach(app.screenshot(), named: "after-open-node-tab")
            XCTFail("Node tab did not open. nav bars: "
                    + app.navigationBars.allElementsBoundByIndex.map(\.identifier)
                        .joined(separator: ", ")
                    + " | tab buttons: "
                    + app.tabBars.buttons.allElementsBoundByIndex
                        .map { "\($0.label)[hittable=\($0.isHittable)]" }
                        .joined(separator: ", "))
            return
        }

        let browse = app.buttons["Browse systems on node"].firstMatch
        if browse.waitForExistence(timeout: 5) {
            browse.tap()
        } else {
            app.staticTexts["Browse systems on node"].firstMatch.tap()
        }

        // The node under test serves eleven systems; any one of them appearing
        // means the list loaded and decoded.
        let loaded = app.staticTexts["Tempest"].waitForExistence(timeout: 20)
            || app.staticTexts["Axis PTZ"].waitForExistence(timeout: 5)

        attach(app.screenshot(), named: "node-tab-systems")

        // The list opens below the fold, so scroll it into view and capture it
        // — a passing existence check on an off-screen element does not prove
        // the rows actually render.
        app.swipeUp()
        app.swipeUp()
        attach(app.screenshot(), named: "node-tab-systems-scrolled")

        XCTAssertTrue(loaded, "no systems listed from \(node)")
    }

    /// Selects a tab whether it is on the bar or behind "More".
    @MainActor
    private func openTab(_ name: String, in app: XCUIApplication) throws {
        let direct = app.tabBars.buttons[name]
        if direct.exists {
            if direct.isHittable {
                direct.tap()
            } else {
                // Present but refusing to scroll into view while a transition
                // settles; a coordinate tap goes straight at its centre.
                direct.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            return
        }
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no \(name) tab and no More tab")
        more.tap()
        let row = app.cells.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) not listed under More")
        row.tap()
    }

    @MainActor
    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
