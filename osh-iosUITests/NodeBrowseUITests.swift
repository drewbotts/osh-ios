import XCTest

// MARK: - NodeBrowseUITests
//
// Drives the app against a real node so the viewer's rendering is checked by
// running it, not by trusting that it compiles. Skipped unless OSH_NODE is set,
// like the other live tests.
//
// Pass the node URL through as TEST_RUNNER_OSH_NODE — xcodebuild does not
// forward the host environment into the simulator process, and strips that
// prefix on the way in.
//
// The server is added with no credentials at all, which is the Pass 3b change
// exercised end to end: a form that used to require a username now does not,
// and the client sends no Authorization header rather than an empty one.

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

        try addServer(node, in: app)

        // ── the system browser ───────────────────────────────────────────────
        try openTab("Node", in: app)
        if !app.navigationBars["Node"].waitForExistence(timeout: 8) {
            attach(app.screenshot(), named: "after-open-node-tab")
            XCTFail("Node tab did not open. nav bars: "
                    + app.navigationBars.allElementsBoundByIndex.map(\.identifier)
                        .joined(separator: ", "))
            return
        }

        // A simulator carried over from an earlier run may already have a
        // server selected — this one is only meaningful against the node the
        // test was given.
        try selectServer("live", in: app)
        attach(app.screenshot(), named: "node-tab")

        let browse = app.buttons["Browse node…"].firstMatch
        if browse.waitForExistence(timeout: 5) {
            browse.tap()
        } else {
            app.staticTexts["Browse node…"].firstMatch.tap()
        }

        XCTAssertTrue(app.navigationBars["Browse node"].waitForExistence(timeout: 10),
                      "the browser did not open")

        // Any system appearing means the listing loaded and its schemas decoded.
        let loaded = app.staticTexts["Tempest"].waitForExistence(timeout: 25)
            || app.staticTexts["Axis PTZ"].waitForExistence(timeout: 5)
            || app.staticTexts["KrakenSDR"].waitForExistence(timeout: 5)
        attach(app.screenshot(), named: "browser-systems")
        XCTAssertTrue(loaded, "no systems listed from \(node)")

        // ── a system dashboard ───────────────────────────────────────────────
        // KrakenSDR is the interesting one: a settings card carrying the
        // station's position, a bearing dial and a spectrum waterfall, in that
        // order. Reached through the search field rather than by scrolling,
        // which also exercises the filter.
        // `.searchable` hides its bar above the first row until the list is
        // pulled down, so an existence check alone finds an element that
        // refuses taps.
        app.swipeDown()
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) && search.isHittable {
            search.tap()
            search.typeText("KrakenSDR")
        }

        let kraken = app.staticTexts["KrakenSDR"].firstMatch
        XCTAssertTrue(kraken.waitForExistence(timeout: 10),
                      "KrakenSDR did not survive the search filter")
        attach(app.screenshot(), named: "browser-filtered")
        kraken.tap()

        // The dashboard's toolbar carries the stream-state summary, which is
        // the cheapest proof that a session actually started.
        let dashboardAppeared = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'live /'"))
            .firstMatch
            .waitForExistence(timeout: 20)
        attach(app.screenshot(), named: "system-dashboard")
        XCTAssertTrue(dashboardAppeared, "the dashboard showed no stream-state summary")

        app.swipeUp()
        attach(app.screenshot(), named: "system-dashboard-scrolled")

        // ── the node map ─────────────────────────────────────────────────────
        try openTab("Map", in: app)
        // Scoped to the segmented control: a bare lookup for "Node" finds the
        // tab-bar button of the same name and walks straight back to the Node
        // tab.
        let nodeSegment = app.segmentedControls.buttons["Node"].firstMatch
        XCTAssertTrue(nodeSegment.waitForExistence(timeout: 8),
                      "the Map tab has no This Device / Node control")
        nodeSegment.tap()
        // Loading every system's schemas takes a moment; the legend appears
        // with the first marker.
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'markers'"))
            .firstMatch
            .waitForExistence(timeout: 40)
        attach(app.screenshot(), named: "node-map")
    }

    // MARK: Steps

    @MainActor
    private func addServer(_ node: String, in app: XCUIApplication) throws {
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

        // Deliberately no username and no password: the node allows anonymous
        // access, and a blank username must now save and connect.
        app.buttons["Save"].tap()

        // Let the save settle before reaching for the tab bar: a tab button
        // underneath a dismissing keyboard reports as present but refuses the
        // accessibility scroll-to-visible action.
        _ = app.navigationBars["Settings"].waitForExistence(timeout: 5)
    }

    /// Makes the named server the active one, through the Node tab's picker.
    @MainActor
    private func selectServer(_ label: String, in app: XCUIApplication) throws {
        // A Picker inside a List renders as a navigation-link row on iOS: the
        // row shows "Server, <current>" and pushes a list of the choices.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Server'"))
            .firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("no Server picker on the Node tab")
            return
        }
        if row.label.contains(label) { return }
        row.tap()

        let choice = app.buttons[label].firstMatch
        if choice.waitForExistence(timeout: 5) {
            choice.tap()
        } else {
            app.staticTexts[label].firstMatch.tap()
        }
        _ = app.navigationBars["Node"].waitForExistence(timeout: 5)
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
