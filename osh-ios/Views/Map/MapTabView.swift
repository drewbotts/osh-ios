import SwiftUI

// MARK: - MapTabView
//
// The Map tab: a navigation stack around the common operating picture.
//
// Everything that used to be here — the This Device / Node segmented control
// and the two maps behind it — is gone. There is one map now; see COPMapView
// for why.

struct MapTabView: View {

    var body: some View {
        NavigationStack {
            COPMapView()
                .navigationTitle("Map")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    MapTabView()
        .previewEnvironment()
}
