import SwiftUI
import MapKit

// MARK: - TrackMapView
//
// Draws a track and its current position. Deliberately knows nothing about
// SensorSession: it takes `[TrackPoint]` and a `currentFix`, so the same view
// will draw a track fetched from an OSH node once the viewer lands. The tab
// above it is the only piece that has to know where the points came from.

struct TrackMapView: View {

    let track: [TrackPoint]
    let currentFix: TrackPoint?

    @Binding var isFollowing: Bool
    let onClearTrack: () -> Void

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            if track.count >= 2 {
                MapPolyline(coordinates: track.map(\.coordinate))
                    .stroke(.blue, lineWidth: 3)
            }

            if let currentFix {
                if let accuracy = currentFix.horizontalAccuracy, accuracy > 0 {
                    MapCircle(center: currentFix.coordinate, radius: accuracy)
                        .foregroundStyle(.blue.opacity(0.15))
                        .stroke(.blue.opacity(0.5), lineWidth: 1)
                }
                Marker("Current fix", systemImage: "location.fill",
                       coordinate: currentFix.coordinate)
                    .tint(.blue)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onChange(of: currentFix) { _, fix in
            guard isFollowing, let fix else { return }
            recenter(on: fix)
        }
        .onChange(of: isFollowing) { _, following in
            guard following, let currentFix else { return }
            recenter(on: currentFix)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $isFollowing) {
                    Label("Follow", systemImage: isFollowing ? "location.fill" : "location")
                }
                .toggleStyle(.button)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear track", systemImage: "trash", action: onClearTrack)
                    .disabled(track.isEmpty)
            }
        }
    }

    /// A fixed span rather than `.automatic`: while following, the camera
    /// should track the fix at a steady zoom instead of rescaling to the whole
    /// route every time a point is added.
    private func recenter(on point: TrackPoint) {
        withAnimation(.easeInOut(duration: 0.25)) {
            camera = .region(MKCoordinateRegion(
                center: point.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))
        }
    }
}

#Preview {
    @Previewable @State var following = true
    let track = PreviewSupport.track()
    return NavigationStack {
        TrackMapView(track: track,
                     currentFix: track.last,
                     isFollowing: $following,
                     onClearTrack: {})
    }
}
