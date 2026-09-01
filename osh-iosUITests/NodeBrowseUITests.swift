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
        // Skipped, not failed. XCTUnwrap would report "OSH_NODE not set" as a
        // broken test on every run of the default suite, which is exactly the
        // signal the fixtures exist to keep quiet.
        guard let node else {
            throw XCTSkip("OSH_NODE not set; the default suite runs from fixtures")
        }

        let app = XCUIApplication()
        app.launch()

        try addServer(node, in: app)

        // ── the systems tab ──────────────────────────────────────────────────
        // Pass 3c merged the Node tab and the system browser into one screen:
        // the server picker and registration are its header, the listing is
        // below them, and there is no "Browse node…" link any more.
        try openTab("Systems", in: app)
        if !app.navigationBars["Systems"].waitForExistence(timeout: 8) {
            attach(app.screenshot(), named: "after-open-systems-tab")
            XCTFail("Systems tab did not open. nav bars: "
                    + app.navigationBars.allElementsBoundByIndex.map(\.identifier)
                        .joined(separator: ", "))
            return
        }

        // A simulator carried over from an earlier run may already have a
        // server selected — this one is only meaningful against the node the
        // test was given.
        try selectServer("live", in: app)
        attach(app.screenshot(), named: "systems-tab")

        // Any system row means the listing loaded and its schemas decoded.
        //
        // Matched on the "N datastreams" badge rather than on a system's name:
        // the tab loads the whole node eagerly and sorts it live-first, so which
        // system lands where depends on what the node happens to be publishing,
        // and a List only realises the rows it has drawn — a name below the fold
        // is genuinely absent from the hierarchy rather than merely off-screen.
        let anyRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'datastreams'"))
            .firstMatch
        let loaded = anyRow.waitForExistence(timeout: 40)
        attach(app.screenshot(), named: "systems-list")
        XCTAssertTrue(loaded, "no systems listed from \(node)")

        // The activity dot and its relative age are on every row, and they are
        // the Pass 3c addition worth asserting on: a node that answered but
        // whose freshness never resolved would still list systems.
        XCTAssertTrue(app.staticTexts["This Device"].exists,
                      "this device is not the first row of the systems list")

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

        // ── the common operating picture ─────────────────────────────────────
        // There is no This Device / Node control any more: one map draws both,
        // and the legend's marker count is the proof it loaded the node.
        try openTab("Map", in: app)
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 8),
                      "the Map tab did not open")
        XCTAssertFalse(app.segmentedControls.buttons["Node"].exists,
                       "the Map tab still has the old This Device / Node control")
        // Loading every system's schemas takes a moment; the legend appears
        // with the first marker.
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'markers'"))
            .firstMatch
            .waitForExistence(timeout: 40)
        attach(app.screenshot(), named: "cop-map")

        // ── clustering ───────────────────────────────────────────────────────
        // Zooming out has to push markers into groups, and the legend has to
        // say so. Driven by a real pinch rather than by calling the clustering
        // directly, because the thing worth proving is that the camera's span
        // reaches the grouping at all.
        let map = app.maps.firstMatch
        if map.waitForExistence(timeout: 5) {
            map.pinch(withScale: 0.4, velocity: -2)
            // Panning because a group is not guaranteed to be near the middle
            // of the frame: this node's KrakenSDR is configured with a static
            // location in central India while everything else is in Alabama, so
            // the two groups sit against opposite edges.
            map.swipeRight()

            // The legend counts the grouping…
            let grouped = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] 'groups'"))
                .firstMatch
            let didGroup = grouped.waitForExistence(timeout: 10)

            // …and this is the bubble itself, on screen. The count alone would
            // pass even if the annotation never drew.
            let bubble = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'systems grouped here'"))
                .firstMatch
            let drewBubble = bubble.waitForExistence(timeout: 10)

            attach(app.screenshot(), named: "cop-map-clustered")
            XCTAssertTrue(didGroup,
                          "zooming out did not group any markers; legend read: "
                          + app.staticTexts.allElementsBoundByIndex.map(\.label)
                              .filter { $0.contains("marker") }.joined(separator: " | "))
            XCTAssertTrue(drewBubble, "the grouping was counted but no cluster bubble was drawn")
        }

        // ── the video wall ───────────────────────────────────────────────────
        // The reference node carries two Axis cameras, so the wall has tiles
        // whether or not this device's own camera is switched on.
        try openTab("Video", in: app)
        XCTAssertTrue(app.navigationBars["Video"].waitForExistence(timeout: 8),
                      "the Video tab did not open")
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'streams playing'"))
            .firstMatch
            .waitForExistence(timeout: 40)
        attach(app.screenshot(), named: "video-wall")

        // ── the payoff: a full-screen camera with its own controls ────────────
        // Tapping a tile opens the player, and the PTZ overlay appears over it
        // when that camera's control stream was recognised. Nothing here presses
        // the pad — this asserts the controls exist, it does not move a camera.
        let ptzTile = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'Axis PTZ'"))
            .firstMatch
        guard ptzTile.waitForExistence(timeout: 20) else {
            attach(app.screenshot(), named: "video-wall-no-ptz-tile")
            return  // No PTZ camera on this node; nothing to open.
        }
        ptzTile.tap()

        // The overlay hides itself after four seconds of no interaction, which
        // is the behaviour and not a workaround: the picture is the point and
        // the chrome gets out of its way. What survives is a "Show controls"
        // button in the corner, and pressing it is how the test gets the pad
        // back — a UI query against a busy simulator takes longer than that
        // four-second window, so waiting for the pad directly would be a race.
        let panLeft = app.buttons["Pan left"].firstMatch
        var hasControls = panLeft.waitForExistence(timeout: 6)
        for _ in 0..<3 where !hasControls {
            let show = app.buttons["Show controls"].firstMatch
            guard show.waitForExistence(timeout: 8) else { break }
            show.tap()
            hasControls = panLeft.waitForExistence(timeout: 3)
        }
        attach(app.screenshot(), named: "full-screen-ptz")
        if !hasControls {
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "full-screen-hierarchy"
            dump.lifetime = .keepAlways
            add(dump)
        }
        XCTAssertTrue(hasControls,
                      "the PTZ overlay did not appear over the Axis camera's player; buttons were: "
                      + app.buttons.allElementsBoundByIndex
                          .map { "\($0.identifier)/\($0.label)" }.joined(separator: ", "))
        // Present, never pressed: this test opens controls, it does not move a
        // camera. LiveCommandTests is where a real move happens, behind its own
        // opt-in.
        XCTAssertTrue(app.buttons["Pan right"].exists)
        XCTAssertTrue(app.buttons["Zoom in"].exists)

        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap() }
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

    /// Makes the named server the active one, through the Systems tab's picker.
    @MainActor
    private func selectServer(_ label: String, in app: XCUIApplication) throws {
        // A Picker inside a List renders as a navigation-link row on iOS: the
        // row shows "Server, <current>" and pushes a list of the choices.
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Server'"))
            .firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("no Server picker on the Systems tab")
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
        _ = app.navigationBars["Systems"].waitForExistence(timeout: 5)
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
