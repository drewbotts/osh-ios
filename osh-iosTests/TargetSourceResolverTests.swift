import Testing
import Foundation
import CoreLocation
@testable import osh_ios

// MARK: - TargetSourceResolverTests
//
// Which system a designated target was observed from.
//
// This is the one rule in the target feature that a schema cannot answer: the
// reference node's range finder record is a timestamp and a lat/lon, and the
// phone that was holding it is nowhere in it. Every case below is a shape that
// really occurs — three that a Connected Systems node can state, one that only
// the UIDs reveal, and one where the honest answer is "nowhere to draw from".

@Suite("Target source resolution")
struct TargetSourceResolverTests {

    // MARK: Building blocks

    /// The captured range finder target stream.
    private static func targetDatastream(id: String = "target") throws -> RemoteDatastream {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.lrfTarget, "schema-binary.json"))
        return RemoteDatastream(summary: DatastreamSummary(id: id, name: "LRF - targetLoc"),
                                schema: schema,
                                decoder: try DatastreamDecoder(datastreamId: id, schema: schema))
    }

    /// A synthetic target stream that names its observer, which is the shape
    /// rule i exists for and the one the node does not serve.
    private static func identifyingDatastream(id: String = "target") throws
        -> (datastream: RemoteDatastream, sourceIdPath: FieldPath) {
        let record = DataRecord(
            definition: "http://sensorml.com/ont/swe/property/RangeFinderOutput",
            label: "Designation", name: "designation",
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "sourceSystem", component: SWEText(
                    definition: "http://sensorml.com/ont/swe/property/SourceSystemUID",
                    label: "Source System")),
                DataField(name: "targetLoc", component: SWEVector(
                    definition: "http://sensorml.com/ont/swe/property/TargetLocation",
                    label: "Target Location",
                    coordinates: [
                        DataField(name: "lat", component: Quantity(
                            definition: "http://sensorml.com/ont/swe/property/GeodeticLatitude",
                            label: "Lat", uom: "deg")),
                        DataField(name: "lon", component: Quantity(
                            definition: "http://sensorml.com/ont/swe/property/Longitude",
                            label: "Lon", uom: "deg"))
                    ]))
            ])

        let schema = SWESchemaDecoder.DatastreamSchema(obsFormat: "application/swe+json",
                                                       recordSchema: record,
                                                       recordEncoding: nil,
                                                       idIndex: [:])
        let datastream = RemoteDatastream(
            summary: DatastreamSummary(id: id, name: "Designation"),
            schema: schema,
            decoder: try DatastreamDecoder(datastreamId: id, schema: schema))

        guard case .target(let paths) = datastream.role,
              let sourceIdPath = paths.sourceIdPath else {
            throw TestFailure.notATargetStream
        }
        return (datastream, sourceIdPath)
    }

    private enum TestFailure: Error { case notATargetStream }

    private static func observation(datastreamId: String = "target",
                                    sourceIdPath: FieldPath? = nil,
                                    statedSource: String? = nil) -> ParsedObservation {
        var values: [FieldPath: FieldValue] = [
            FieldPath("/targetLoc/lat"): .double(31.2026),
            FieldPath("/targetLoc/lon"): .double(-89.1819),
            FieldPath("/location/lat"): .double(31.2026),
            FieldPath("/location/lon"): .double(-89.1819)
        ]
        if let sourceIdPath, let statedSource {
            values[sourceIdPath] = .text(statedSource)
        }
        return ParsedObservation(datastreamId: datastreamId,
                                 phenomenonTime: Date(timeIntervalSince1970: 1_700_000_000),
                                 values: values,
                                 orderedPaths: Array(values.keys))
    }

    /// A system with a registered geometry, so `hasPosition` is true and the
    /// default position lookup can find it without any observations.
    private static func positioned(id: String,
                                   uid: String?,
                                   name: String,
                                   at coordinate: CLLocationCoordinate2D,
                                   parentSystemId: String? = nil) -> RemoteSystem {
        RemoteSystem(summary: SystemSummary(id: id, uid: uid, name: name,
                                            parentSystemId: parentSystemId),
                     subsystems: [], datastreams: [], controlStreams: [],
                     fixedLocation: coordinate)
    }

    private static func unpositioned(id: String,
                                     uid: String?,
                                     name: String,
                                     parentSystemId: String? = nil) -> RemoteSystem {
        RemoteSystem(summary: SystemSummary(id: id, uid: uid, name: name,
                                            parentSystemId: parentSystemId),
                     subsystems: [], datastreams: [], controlStreams: [],
                     fixedLocation: nil)
    }

    private static let phonePoint = CLLocationCoordinate2D(latitude: 31.20267,
                                                           longitude: -89.18167)

    // MARK: i — the record names the source

    @Test("A stated identifier matching a system id wins over everything else")
    func identifierMatchesSystemId() throws {
        let (datastream, sourceIdPath) = try Self.identifyingDatastream()
        let phone = Self.positioned(id: "phone1", uid: "urn:osh:android:abcd1234",
                                    name: "Android", at: Self.phonePoint)
        // The owner has a position *and* a parent, so rules ii and iii would
        // both fire. Rule i has to beat them.
        let owner = Self.positioned(id: "lrf", uid: "urn:lasertech:trupulse360:abcd1234",
                                    name: "LRF",
                                    at: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                    parentSystemId: "phone1")

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(sourceIdPath: sourceIdPath, statedSource: "phone1"),
            datastream: datastream,
            owner: owner,
            systems: [owner, phone],
            localDevice: nil))

        #expect(source.resolution == .identifier)
        #expect(source.systemId == "phone1")
        #expect(source.coordinate?.latitude == Self.phonePoint.latitude)
    }

    @Test("A stated identifier that is only a suffix of the UID still matches")
    func identifierMatchesUIDSuffix() throws {
        let (datastream, sourceIdPath) = try Self.identifyingDatastream()
        let phone = Self.positioned(id: "phone1",
                                    uid: "urn:osh:android:7ae57419dd427e4c:droid2",
                                    name: "Android Sensors", at: Self.phonePoint)
        let owner = Self.unpositioned(id: "lrf", uid: "urn:lasertech:trupulse360", name: "LRF")

        // What a driver actually writes: the tail of the UID it knows about.
        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(sourceIdPath: sourceIdPath,
                                  statedSource: "android:7ae57419dd427e4c:droid2"),
            datastream: datastream,
            owner: owner,
            systems: [owner, phone],
            localDevice: nil))

        #expect(source.resolution == .identifier)
        #expect(source.systemId == "phone1")
    }

    @Test("This device is a candidate for a stated identifier like any other system")
    func identifierMatchesLocalDevice() throws {
        let (datastream, sourceIdPath) = try Self.identifyingDatastream()
        let owner = Self.unpositioned(id: "lrf", uid: "urn:lasertech:trupulse360", name: "LRF")
        let device = TargetSourceResolver.LocalDeviceRef(
            systemId: "0a0g",
            uid: "urn:osh:ios:e8cd0bd5-bb37-4aa3-8a55-af488a95936c",
            markerId: "__this_device__",
            coordinate: Self.phonePoint)

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(sourceIdPath: sourceIdPath,
                                  statedSource: "urn:osh:ios:e8cd0bd5-bb37-4aa3-8a55-af488a95936c"),
            datastream: datastream,
            owner: owner,
            systems: [owner],
            localDevice: device))

        #expect(source.resolution == .identifier)
        #expect(source.isLocalDevice)
        #expect(source.systemId == "__this_device__")
        #expect(source.coordinate?.latitude == Self.phonePoint.latitude)
    }

    @Test("An identifier naming nothing on the node falls through to the next rule")
    func unknownIdentifierFallsThrough() throws {
        let (datastream, sourceIdPath) = try Self.identifyingDatastream()
        let owner = Self.positioned(id: "lrf", uid: "urn:lasertech:trupulse360", name: "LRF",
                                    at: Self.phonePoint)

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(sourceIdPath: sourceIdPath, statedSource: "somebody-else"),
            datastream: datastream,
            owner: owner,
            systems: [owner],
            localDevice: nil))

        #expect(source.resolution == .owner)
    }

    // MARK: ii — a parent system

    @Test("A parent link is the source when the record names nobody")
    func parentSystem() throws {
        let datastream = try Self.targetDatastream()
        let phone = Self.positioned(id: "phone1", uid: "urn:osh:android:abcd1234",
                                    name: "Android", at: Self.phonePoint)
        let owner = Self.unpositioned(id: "lrf", uid: "urn:lasertech:trupulse360",
                                      name: "LRF", parentSystemId: "phone1")

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: owner,
            systems: [owner, phone],
            localDevice: nil))

        #expect(source.resolution == .parent)
        #expect(source.systemId == "phone1")
        #expect(source.coordinate?.latitude == Self.phonePoint.latitude)
    }

    // MARK: iii — the owner itself

    @Test("A target stream on a positioned system is observed from that system")
    func ownerIsTheSource() throws {
        let datastream = try Self.targetDatastream()
        // Case (c): the driver publishes the target output on the phone's own
        // system, so there is nothing to look up.
        let phone = Self.positioned(id: "phone1", uid: "urn:osh:android:abcd1234",
                                    name: "Android", at: Self.phonePoint)

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: phone,
            systems: [phone],
            localDevice: nil))

        #expect(source.resolution == .owner)
        #expect(source.systemId == "phone1")
        #expect(source.hasPosition)
    }

    // MARK: iv — UID affinity

    /// The reference node's actual shape, UIDs and all: two registrations
    /// sharing a sixteen-character device id and nothing else connecting them.
    @Test("A shared device token in the UID locates the phone the range finder is carried by")
    func uidAffinity() throws {
        let datastream = try Self.targetDatastream()
        let owner = Self.unpositioned(
            id: "02nqpau0r420",
            uid: "urn:lasertech:trupulse360:7ae57419dd427e4c:replay",
            name: "Laser Range Finder LRF")
        let livePhone = Self.positioned(
            id: "02cfdsfiopmg",
            uid: "urn:osh:android:7ae57419dd427e4c:droid2:replay",
            name: "Android", at: Self.phonePoint)
        let olderPhone = Self.positioned(
            id: "0k0g",
            uid: "urn:osh:android:7ae57419dd427e4c:droid2",
            name: "Android Sensors [Android2-0253]",
            at: CLLocationCoordinate2D(latitude: 1, longitude: 1))
        let unrelated = Self.positioned(id: "0g0g", uid: "urn:osh:sensor:krakensdr:kraken002",
                                        name: "KrakenSDR",
                                        at: CLLocationCoordinate2D(latitude: 2, longitude: 2))

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: owner,
            systems: [owner, unrelated, olderPhone, livePhone],
            localDevice: nil))

        #expect(source.resolution == .uidAffinity)
        // Both phones share the device id; the live one also shares ":replay",
        // and that is the tiebreak.
        #expect(source.systemId == "02cfdsfiopmg")
    }

    /// The other half of the reference node's pair. This range finder's UID
    /// ends at the device id, so ":replay" cannot break the tie — and the
    /// archived phone, whose UID carries one fewer unshared segment, is the
    /// closer relative.
    @Test("On an equal token score the UID that says least beyond them wins")
    func uidAffinityTieBreaksOnTheTighterUID() throws {
        let datastream = try Self.targetDatastream()
        let owner = Self.unpositioned(
            id: "0k10", uid: "urn:lasertech:trupulse360:7ae57419dd427e4c",
            name: "TruPulse Range Finder [Android2-0253]")
        let livePhone = Self.positioned(
            id: "02cfdsfiopmg", uid: "urn:osh:android:7ae57419dd427e4c:droid2:replay",
            name: "Android", at: Self.phonePoint)
        let archivedPhone = Self.positioned(
            id: "0k0g", uid: "urn:osh:android:7ae57419dd427e4c:droid2",
            name: "Android Sensors [Android2-0253]",
            at: CLLocationCoordinate2D(latitude: 31.2, longitude: -89.18))

        // Listed live-first, so a rule that kept the first tie would get this
        // wrong.
        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: owner,
            systems: [owner, livePhone, archivedPhone],
            localDevice: nil))

        #expect(source.resolution == .uidAffinity)
        #expect(source.systemId == "0k0g")
    }

    @Test("Affinity never overrides a positioned owner")
    func affinityLosesToOwner() throws {
        let datastream = try Self.targetDatastream()
        let owner = Self.positioned(
            id: "lrf", uid: "urn:lasertech:trupulse360:7ae57419dd427e4c:replay",
            name: "LRF", at: CLLocationCoordinate2D(latitude: 5, longitude: 5))
        let phone = Self.positioned(
            id: "phone1", uid: "urn:osh:android:7ae57419dd427e4c:droid2:replay",
            name: "Android", at: Self.phonePoint)

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: owner,
            systems: [owner, phone],
            localDevice: nil))

        #expect(source.resolution == .owner)
        #expect(source.systemId == "lrf")
    }

    @Test("A short or generic UID token pairs nothing")
    func genericTokensDoNotPair() throws {
        let datastream = try Self.targetDatastream()
        // "osh", "ios" and "replay" are all shorter than eight characters, so
        // there is no strong token in common and no line to draw.
        let owner = Self.unpositioned(id: "lrf", uid: "urn:osh:lrf:replay", name: "LRF")
        let phone = Self.positioned(id: "phone1", uid: "urn:osh:android:replay",
                                    name: "Android", at: Self.phonePoint)

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: owner,
            systems: [owner, phone],
            localDevice: nil))

        #expect(source.resolution == .ownerWithoutPosition)
        #expect(!source.hasPosition)
    }

    // MARK: A source nothing can place

    @Test("A source with no position resolves, carries no coordinate, and draws no line")
    func sourceWithoutPosition() throws {
        let datastream = try Self.targetDatastream()
        let owner = Self.unpositioned(id: "lrf",
                                      uid: "urn:lasertech:trupulse360:7ae57419dd427e4c",
                                      name: "Laser Range Finder LRF")

        let source = try #require(TargetSourceResolver.source(
            for: Self.observation(),
            datastream: datastream,
            owner: owner,
            systems: [owner],
            localDevice: nil))

        // Still a source — the target marker is drawn and the card names the
        // range finder — with nothing to start a line from.
        #expect(source.resolution == .ownerWithoutPosition)
        #expect(source.systemId == "lrf")
        #expect(source.coordinate == nil)
        #expect(!source.hasPosition)
    }

    @Test("A stream that is not a target stream has no source at all")
    func nonTargetStreamHasNoSource() throws {
        let schema = try SWESchemaDecoder.decode(
            try FixtureLoader.requiredData(.krakenDOA, "schema-binary.json"))
        let doa = RemoteDatastream(summary: DatastreamSummary(id: "doa", name: "KrakenSDR - DoA"),
                                   schema: schema,
                                   decoder: try DatastreamDecoder(datastreamId: "doa",
                                                                   schema: schema))
        let owner = Self.positioned(id: "kraken", uid: "urn:osh:sensor:krakensdr:kraken002",
                                    name: "KrakenSDR", at: Self.phonePoint)

        #expect(TargetSourceResolver.source(for: Self.observation(),
                                            datastream: doa,
                                            owner: owner,
                                            systems: [owner],
                                            localDevice: nil) == nil)
    }

    // MARK: UID tokenising

    @Test("UID tokens drop urn and treat only long segments as identifying")
    func uidTokens() {
        let tokens = TargetSourceResolver.tokens(of: "urn:osh:android:7ae57419dd427e4c:droid2")
        #expect(!tokens.all.contains("urn"))
        #expect(tokens.all.contains("android"))
        #expect(tokens.strong == ["7ae57419dd427e4c"])

        #expect(TargetSourceResolver.tokens(of: nil).all.isEmpty)
        #expect(TargetSourceResolver.tokens(of: "urn:osh:ios").strong.isEmpty)
    }

    // MARK: Label formatting

    @Test("A target label reads as range and three-digit azimuth")
    func labelFormatting() {
        #expect(TargetStyle.label(rangeMeters: 412, azimuthDegrees: 87) == "412 m @ 087°")
        #expect(TargetStyle.label(rangeMeters: 2400, azimuthDegrees: nil) == "2.4 km")
        #expect(TargetStyle.label(rangeMeters: nil, azimuthDegrees: 372) == "@ 012°")
        #expect(TargetStyle.label(rangeMeters: nil, azimuthDegrees: nil) == nil)
        #expect(TargetStyle.label(rangeMeters: .nan, azimuthDegrees: .nan) == nil)
    }

    @Test("A target line fades on the same clock as a bearing and is never removed")
    func fadeMatchesBearings() {
        let now = Date()
        #expect(TargetStyle.opacity(at: now, now: now) == TargetStyle.freshOpacity)
        #expect(TargetStyle.opacity(at: now.addingTimeInterval(-BearingStyle.staleAfter - 1),
                                    now: now) == TargetStyle.staleOpacity)
        #expect(TargetStyle.staleOpacity > 0, "a stale target line stays visible")
    }
}
