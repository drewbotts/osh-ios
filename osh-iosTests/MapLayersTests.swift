import Testing
import Foundation
@testable import osh_ios

// MARK: - MapLayersTests
//
// The persisted layer switches. The one behaviour worth pinning is tolerance:
// a settings blob written before a layer existed must decode to that layer's
// default rather than fail — a new toggle should never cost the user every
// other map setting they had.

@Suite("Map layers")
struct MapLayersTests {

    @Test("Defaults: everything on except the two questions the user has to ask")
    func defaults() {
        let layers = MapLayers()
        #expect(layers.thisDevice && layers.nodeSystems && layers.tracks
                && layers.bearingLines && layers.labels && layers.clusterMarkers
                && layers.liveUpdates)
        #expect(!layers.targetHistory)
        #expect(!layers.liveOnly)
    }

    @Test("A blob written before liveOnly existed decodes with liveOnly off")
    func missingLiveOnlyFallsBack() throws {
        let json = #"{"thisDevice":false,"nodeSystems":true,"liveUpdates":false}"#
        let layers = try JSONDecoder().decode(MapLayers.self, from: Data(json.utf8))
        #expect(!layers.thisDevice)
        #expect(!layers.liveUpdates)
        #expect(!layers.liveOnly)
        // Untouched fields keep their defaults.
        #expect(layers.tracks && layers.labels)
    }

    @Test("liveOnly survives a round trip")
    func roundTrip() throws {
        var layers = MapLayers()
        layers.liveOnly = true
        let data = try JSONEncoder().encode(layers)
        let decoded = try JSONDecoder().decode(MapLayers.self, from: data)
        #expect(decoded == layers)
        #expect(decoded.liveOnly)
    }
}
