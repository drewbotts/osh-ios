import WidgetKit
import SwiftUI

// MARK: - OSHiOSWidgetsBundle
//
// The extension's entry point. It carries the streaming Live Activity and
// nothing else: there are no Home Screen widgets, because nothing this app
// knows is useful without a session running.

@main
struct OSHiOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivityWidget()
    }
}
