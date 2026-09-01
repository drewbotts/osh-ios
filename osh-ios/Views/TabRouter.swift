import SwiftUI

// MARK: - TabRouter
//
// Which tab is showing, so a screen can send the user to another one.
//
// Two callers. The Systems tab lists this device as its first row, and tapping
// that row has to land on Live — a row that described where to go instead of
// going there would be the only inert row in the list. And a target card names
// the system the target was observed *from*, which is a marker on the map;
// tapping the name has to arrive there with that marker already selected.

@MainActor
final class TabRouter: ObservableObject {

    enum Tab: Hashable {
        case live, video, map, systems, logs, settings
    }

    @Published var selection: Tab = .live

    /// A marker id the map should select when it next appears, and clear.
    ///
    /// Held here rather than pushed into the map because the map may not exist
    /// yet: switching tabs is what builds it.
    @Published var pendingMapSelection: String?

    /// Sends the user to the map with `markerId` selected.
    func showOnMap(markerId: String) {
        pendingMapSelection = markerId
        selection = .map
    }
}
