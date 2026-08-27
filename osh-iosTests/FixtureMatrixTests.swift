import Testing
import Foundation
@testable import osh_ios

// MARK: - FixtureMatrixTests
//
// The same checks applied to every captured fixture, so a newly captured
// datastream is exercised by simply existing rather than by someone remembering
// to write tests for it.
//
// These are deliberately structural — "every leaf got a value", "every member
// ref resolves" — because that is the class of bug that a decoder written
// against one schema shape has against another. Value-level assertions live in
// SWEParserTreeTests.

@Suite("Fixture matrix")
struct FixtureMatrixTests {

    // MARK: Schemas

    @Test("Every swe+json schema decodes and has leaves and a time",
          arguments: FixtureLoader.Slug.allCases)
    func jsonSchemaDecodes(slug: FixtureLoader.Slug) throws {
        guard let data = FixtureLoader.data(slug, "schema-json.json")
                ?? FixtureLoader.data(slug, "control-schema.json") else { return }

        let schema = try SWESchemaDecoder.decode(data)
        let leaves = SchemaWalker.leafPaths(of: schema.recordSchema)
        #expect(!leaves.isEmpty)

        let tree = try SWEParserTree(schema: schema)
        // A control stream's params carry no time; an observation schema must.
        if FixtureLoader.data(slug, "schema-json.json") != nil {
            #expect(tree.phenomenonTimePath != nil)
        }
    }

    @Test("Every binary schema decodes and every member ref resolves to a leaf",
          arguments: FixtureLoader.Slug.allCases)
    func binaryMemberRefsResolve(slug: FixtureLoader.Slug) throws {
        guard let data = FixtureLoader.data(slug, "schema-binary.json") else { return }

        let schema = try SWESchemaDecoder.decode(data)
        let encoding = try #require(schema.recordEncoding)
        #expect(!encoding.members.isEmpty)

        // Every ref must name a real leaf of the parser tree. This is what
        // catches a ref-normalisation slip: an unresolvable ref does not throw
        // at decode time, it reads the wrong number of bytes at run time and
        // corrupts every field after it.
        //
        // Compared against the tree's own encoding-form paths rather than
        // SchemaWalker's, because the two disagree on purpose: SchemaWalker
        // stops at a DataArray, while an encoding addresses the array's
        // element type ("/frequency_axis/frequency").
        let tree = try SWEParserTree(schema: schema)
        let valid = Set(tree.encodingLeafPaths.map(\.description))

        for member in encoding.members {
            #expect(valid.contains(member.ref),
                    "\(slug.rawValue): member ref \(member.ref) resolves to nothing")
        }
    }

    // MARK: JSON observations

    @Test("Every swe+json observation decodes with a finite time and full leaves",
          arguments: FixtureLoader.Slug.allCases)
    func sweJSONObservations(slug: FixtureLoader.Slug) throws {
        guard let obsData = FixtureLoader.data(slug, "obs-json.json"),
              let schemaData = FixtureLoader.data(slug, "schema-json.json") else { return }

        let decoder = try DatastreamDecoder(datastreamId: slug.rawValue,
                                            schema: try SWESchemaDecoder.decode(schemaData))
        let observations = try decoder.decode(json: obsData)

        let raw = try JSONSerialization.jsonObject(with: obsData)
        let expectedCount = (raw as? [Any])?.count
            ?? ((raw as? [String: Any])?["items"] as? [Any])?.count
        #expect(observations.count == expectedCount)
        #expect(!observations.isEmpty)

        for observation in observations {
            #expect(observation.phenomenonTime.timeIntervalSince1970.isFinite)
            // Every leaf the schema declares got a value — a silently skipped
            // field is the failure mode a count check would miss.
            for path in observation.orderedPaths {
                #expect(observation.values[path] != nil)
            }
            #expect(observation.orderedPaths.count == observation.values.count)
        }
    }

    @Test("om+json phenomenonTime matches the envelope string",
          arguments: FixtureLoader.Slug.allCases)
    func omJSONObservations(slug: FixtureLoader.Slug) throws {
        guard let obsData = FixtureLoader.data(slug, "obs-omjson.json"),
              let schemaData = FixtureLoader.data(slug, "schema-json.json") else { return }

        let schema = try SWESchemaDecoder.decode(schemaData)
        let tree = try SWEParserTree(schema: schema)
        let decoder = try DatastreamDecoder(datastreamId: slug.rawValue, schema: schema)
        let observations = try decoder.decode(json: obsData)

        let root = try #require(try JSONSerialization.jsonObject(with: obsData) as? [String: Any])
        let items = try #require(root["items"] as? [[String: Any]])
        #expect(observations.count == items.count)

        for (observation, item) in zip(observations, items) {
            let stamp = try #require(item["phenomenonTime"] as? String)
            let envelope = try #require(JSONTokenSource.parseTime(stamp))
            let result = item["result"] as? [String: Any] ?? [:]

            // The record's own Time wins when the result carries one, and the
            // envelope is the fallback when it does not. Both cases are real:
            // the node omits the Time field from om+json results for some of
            // its drivers, and on a replayed datastream the envelope's instant
            // and the record's differ by the age of the archive — here weeks.
            //
            // Looked up by the schema's own time path rather than by scanning
            // the result for anything date-shaped: an AIS MMSI is a nine-digit
            // string and parses perfectly well as an epoch.
            let timeField = tree.phenomenonTimePath?.lastComponent
            let recordTime = timeField
                .flatMap { result[$0] as? String }
                .flatMap(JSONTokenSource.parseTime)

            #expect(abs(observation.phenomenonTime
                .timeIntervalSince(recordTime ?? envelope)) < 0.001)
        }
    }

    // MARK: Binary observations

    @Test("Every binary message decodes to one observation",
          arguments: FixtureLoader.Slug.allCases)
    func binaryObservations(slug: FixtureLoader.Slug) throws {
        guard FixtureLoader.data(slug, "obs-binary.bin") != nil,
              let schemaData = FixtureLoader.data(slug, "schema-binary.json") else { return }

        let schema = try SWESchemaDecoder.decode(schemaData)
        let decoder = try DatastreamDecoder(datastreamId: slug.rawValue, schema: schema)

        for message in try FixtureLoader.binaryMessages(slug) {
            let observations = try decoder.decode(binary: message)
            #expect(observations.count == 1,
                    "\(slug.rawValue): one message should be one record")

            let observation = try #require(observations.first)
            #expect(observation.phenomenonTime.timeIntervalSince1970.isFinite)

            if decoder.isBinaryBlockStream {
                let blocks = observation.values.values.compactMap { value -> Data? in
                    if case .block(let data, _) = value { return data }
                    return nil
                }
                let block = try #require(blocks.first)
                #expect(!block.isEmpty)

                for case .block(_, let compression) in observation.values.values {
                    #expect(compression == decoder.blockCompression)
                }
            }
        }
    }

    @Test("Binary and swe+json agree field for field",
          arguments: FixtureLoader.Slug.allCases)
    func binaryAgreesWithJSON(slug: FixtureLoader.Slug) throws {
        guard let jsonSchema = FixtureLoader.data(slug, "schema-json.json"),
              let jsonObs = FixtureLoader.data(slug, "obs-json.json"),
              let binarySchema = FixtureLoader.data(slug, "schema-binary.json"),
              FixtureLoader.data(slug, "obs-binary.bin") != nil else { return }

        let jsonDecoder = try DatastreamDecoder(
            datastreamId: slug.rawValue, schema: try SWESchemaDecoder.decode(jsonSchema))
        let binaryDecoder = try DatastreamDecoder(
            datastreamId: slug.rawValue, schema: try SWESchemaDecoder.decode(binarySchema))

        let fromJSON = try jsonDecoder.decode(json: jsonObs)
        let fromBinary = try FixtureLoader.binaryMessages(slug)
            .flatMap { try binaryDecoder.decode(binary: $0) }

        // The two captures are separate requests, so they only line up when a
        // timestamp matches. When none does — an archive-only stream captured
        // at different moments — finiteness is all that can be asserted.
        var compared = 0
        for json in fromJSON {
            guard let binary = fromBinary.first(where: {
                abs($0.phenomenonTime.timeIntervalSince(json.phenomenonTime)) < 0.001
            }) else { continue }
            compared += 1

            for path in json.orderedPaths {
                guard let a = json.values[path], let b = binary.values[path] else { continue }
                if let x = a.asDouble, let y = b.asDouble {
                    #expect(abs(x - y) <= max(abs(x), abs(y)) * 1e-6 + 1e-9,
                            "\(slug.rawValue) \(path): \(x) vs \(y)")
                } else {
                    #expect(a == b, "\(slug.rawValue) \(path)")
                }
            }
        }

        if compared == 0 {
            for observation in fromBinary {
                #expect(observation.phenomenonTime.timeIntervalSince1970.isFinite)
            }
        }
    }

    // MARK: Fixture tree health

    @Test("The captured fixture folders are the ones the loader knows about")
    func fixturesArePresent() {
        // Guards against a fixture folder being renamed on disk without the
        // Slug enum following, which would otherwise silently skip every test
        // above for that datastream.
        #expect(FixtureLoader.presentSlugs.count == FixtureLoader.Slug.allCases.count)
    }
}
