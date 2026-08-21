import Foundation
import Testing
@testable import osh_ios

// MARK: - ReadModels decoding
//
// An OSH node answers /systems as GeoJSON (identity inside `properties`) and
// /datastreams with link-style keys such as "system@id". These fixtures are
// trimmed real responses; the point of the tests is that neither shape, and no
// unfamiliar extra key, costs the caller the whole collection.

struct ReadModelsTests {

    // MARK: Fixtures

    /// GET /systems — GeoJSON feature collection wrapped in the `items` envelope.
    private static let systemsListJSON = """
    {
      "items": [
        {
          "type": "Feature",
          "id": "9fkr1r0ldmqbc",
          "properties": {
            "featureType": "http://www.w3.org/ns/sosa/Sensor",
            "uid": "urn:osh:ios:5c1a4f60-2e1b-4d1a-9f36-9a2b0e1c7d55",
            "name": "Drew's iPhone",
            "description": "iOS Connected Systems client",
            "validTime": ["2026-08-01T00:00:00Z", "now"]
          },
          "geometry": null,
          "links": [
            { "rel": "canonical", "href": "http://node/api/systems/9fkr1r0ldmqbc" }
          ]
        },
        {
          "type": "Feature",
          "id": "abc123",
          "properties": {
            "uid": "urn:osh:sensor:weather:001",
            "name": "Weather Station",
            "parent@id": "9fkr1r0ldmqbc"
          }
        }
      ],
      "links": [
        { "rel": "self", "href": "http://node/api/systems?limit=100" }
      ]
    }
    """

    /// GET /systems/{id}/datastreams — note the "@"-suffixed link keys.
    private static let datastreamsListJSON = """
    {
      "items": [
        {
          "id": "ds01",
          "name": "gps_data",
          "outputName": "gps_data",
          "system@id": "9fkr1r0ldmqbc",
          "system@link": { "href": "http://node/api/systems/9fkr1r0ldmqbc" },
          "validTime": ["2026-08-01T00:00:00Z", "now"],
          "phenomenonTimeRange": ["2026-08-01T00:00:00Z", "2026-08-20T12:00:00Z"],
          "resultTimeRange": ["2026-08-01T00:00:00Z", "2026-08-20T12:00:00Z"],
          "formats": ["application/swe+json", "application/swe+csv"],
          "live": true
        },
        {
          "id": "ds02",
          "outputName": "camera0_H264",
          "system@link": "http://node/api/systems/9fkr1r0ldmqbc",
          "formats": ["application/swe+binary"],
          "unexpectedFutureKey": { "nested": [1, 2, 3] }
        }
      ],
      "links": []
    }
    """

    // MARK: Systems

    @Test func systemsListDecodesGeoJSONProperties() throws {
        let data = try #require(Self.systemsListJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(ItemsResponse<SystemSummary>.self, from: data)
        #expect(response.items.count == 2)

        let first = try #require(response.items.first)
        #expect(first.id == "9fkr1r0ldmqbc")
        #expect(first.name == "Drew's iPhone")
        #expect(first.uid == "urn:osh:ios:5c1a4f60-2e1b-4d1a-9f36-9a2b0e1c7d55")
        #expect(first.description == "iOS Connected Systems client")
        #expect(first.validTime == ["2026-08-01T00:00:00Z", "now"])
        #expect(first.parentSystemId == nil)
    }

    /// The GeoJSON envelope's "type":"Feature" describes the encoding, not the
    /// system — surfacing it as the system's type would be actively misleading.
    @Test func featureEnvelopeTypeIsNotTreatedAsTheSystemType() throws {
        let data = try #require(Self.systemsListJSON.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<SystemSummary>.self, from: data).items
        #expect(items[0].type == "http://www.w3.org/ns/sosa/Sensor")
        #expect(items[1].type == nil)
    }

    @Test func parentLinkIsCarriedThrough() throws {
        let data = try #require(Self.systemsListJSON.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<SystemSummary>.self, from: data).items
        #expect(items[1].parentSystemId == "9fkr1r0ldmqbc")
    }

    /// SensorML-JSON spells identity `label` / `uniqueId` and keeps it flat.
    @Test func sensorMLShapeDecodesToo() throws {
        let json = """
        { "id": "s1", "uniqueId": "urn:osh:x", "label": "Flat System", "type": "PhysicalSystem" }
        """
        let data = try #require(json.data(using: .utf8))
        let system = try JSONDecoder().decode(SystemSummary.self, from: data)
        #expect(system.name == "Flat System")
        #expect(system.uid == "urn:osh:x")
        #expect(system.type == "PhysicalSystem")
    }

    // MARK: Datastreams

    @Test func datastreamsListDecodesAtKeys() throws {
        let data = try #require(Self.datastreamsListJSON.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<DatastreamSummary>.self, from: data).items
        #expect(items.count == 2)

        let gps = try #require(items.first)
        #expect(gps.id == "ds01")
        #expect(gps.name == "gps_data")
        #expect(gps.outputName == "gps_data")
        #expect(gps.systemId == "9fkr1r0ldmqbc")
        #expect(gps.formats == ["application/swe+json", "application/swe+csv"])
        #expect(gps.live == true)
        #expect(gps.phenomenonTimeRange?.count == 2)
    }

    /// "system@link" may be an object or a bare href; either yields the id.
    @Test func systemLinkFallsBackToItsLastPathComponent() throws {
        let data = try #require(Self.datastreamsListJSON.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<DatastreamSummary>.self, from: data).items
        #expect(items[1].systemId == "9fkr1r0ldmqbc")
    }

    /// A row with no "name" still has to be displayable, and an unknown key
    /// must not fail the row — let alone the whole collection.
    @Test func missingNameFallsBackAndUnknownKeysAreIgnored() throws {
        let data = try #require(Self.datastreamsListJSON.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<DatastreamSummary>.self, from: data).items
        #expect(items[1].name == "camera0_H264")
        #expect(items[1].live == nil)
    }

    // MARK: Envelope

    /// The live node spells these without the "Range" suffix. Coding against the
    /// OGC schema's longer form alone left both fields permanently nil, which is
    /// how the Datastream detail view ended up with an empty Time section.
    @Test func nodeSpellingOfTimeRangesDecodes() throws {
        let json = """
        {
          "id": "0450",
          "name": "gps_data",
          "outputName": "gps_data",
          "system@id": "041g",
          "validTime": ["2026-08-21T18:14:09.004212Z", "now"],
          "phenomenonTime": ["2026-08-21T18:20:02.483Z", "2026-08-21T18:20:38.73Z"],
          "resultTime": ["2026-08-21T18:20:02.483Z", "2026-08-21T18:20:38.73Z"],
          "resultType": "vector",
          "observedProperties": [
            { "definition": "http://sensorml.com/ont/swe/property/LocationVector",
              "label": "Location" }
          ],
          "formats": ["application/om+json", "application/swe+json"]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let datastream = try JSONDecoder().decode(DatastreamSummary.self, from: data)

        #expect(datastream.phenomenonTimeRange == ["2026-08-21T18:20:02.483Z", "2026-08-21T18:20:38.73Z"])
        #expect(datastream.resultTimeRange == ["2026-08-21T18:20:02.483Z", "2026-08-21T18:20:38.73Z"])
        #expect(datastream.validTime == ["2026-08-21T18:14:09.004212Z", "now"])
        #expect(datastream.systemId == "041g")
        #expect(datastream.live == nil)
    }

    @Test func bareArrayResponseDecodesWithoutTheEnvelope() throws {
        let json = """
        [ { "id": "ds01", "name": "gps_data" } ]
        """
        let data = try #require(json.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<DatastreamSummary>.self, from: data).items
        #expect(items.map(\.id) == ["ds01"])
    }

    @Test func numericIdsDecodeAsStrings() throws {
        let json = """
        { "items": [ { "id": 42, "name": "gps_data" } ] }
        """
        let data = try #require(json.data(using: .utf8))
        let items = try JSONDecoder().decode(ItemsResponse<DatastreamSummary>.self, from: data).items
        #expect(items.first?.id == "42")
    }
}
