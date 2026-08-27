import Foundation

// MARK: - FixtureLoader
//
// Reads the captured node documents under osh-iosTests/Fixtures.
//
// Located from #filePath rather than from the test bundle. The fixture tree has
// six folders each containing a "datastream.json" and a "schema-json.json", and
// a synchronized Xcode group copies resources into the bundle root without
// their directory structure — so bundle lookup would resolve every slug's
// schema to whichever one won the name collision. Reading from the source tree
// keeps each slug's documents distinct and keeps the fixtures diffable in git.

enum FixtureLoader {

    /// Fixture slugs, one per captured datastream or control stream.
    enum Slug: String, CaseIterable {
        case weather            // plain scalar record: Quantity + Count + Text
        case aisVesselLocation  = "ais-vessel-location"  // Boolean/Category/Text/Vector/nilValues
        case spectrumArray      = "spectrum-array"       // variable-size DataArray via href
        case videoMJPEG         = "video-mjpeg"          // nested DataArray + BinaryBlock
        case gps                                          // Time + Vector, as this app writes
        case krakenSettings     = "kraken-settings"      // deeply nested DataRecord
        case choicePTZControl   = "choice-ptz-control"   // DataChoice (control stream)
    }

    /// osh-iosTests/Fixtures, resolved from this file's own location.
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func directory(_ slug: Slug) -> URL {
        root.appendingPathComponent(slug.rawValue, isDirectory: true)
    }

    /// Raw bytes of one fixture file, or nil when that fixture was not captured
    /// — the video stream has no swe+json schema, and the node answers 400 for
    /// it, so "absent" is itself a fact worth being able to assert on.
    static func data(_ slug: Slug, _ name: String) -> Data? {
        try? Data(contentsOf: directory(slug).appendingPathComponent(name))
    }

    /// Bytes of a fixture that must exist; a nil here is a broken checkout, not
    /// a test condition.
    static func requiredData(_ slug: Slug, _ name: String) throws -> Data {
        guard let data = data(slug, name) else {
            throw FixtureError.missing(slug: slug.rawValue, file: name)
        }
        return data
    }

    /// The recorded byte length of each message in `obs-binary.bin`, which is a
    /// plain concatenation and cannot otherwise be split.
    static func binaryMessages(_ slug: Slug) throws -> [Data] {
        let blob = try requiredData(slug, "obs-binary.bin")
        let index = try requiredData(slug, "obs-binary.index.json")

        guard let object = try JSONSerialization.jsonObject(with: index) as? [String: Any],
              let lengths = object["messageLengths"] as? [Int] else {
            throw FixtureError.malformedIndex(slug: slug.rawValue)
        }

        var messages: [Data] = []
        var offset = 0
        for length in lengths {
            guard offset + length <= blob.count else {
                throw FixtureError.malformedIndex(slug: slug.rawValue)
            }
            messages.append(blob.subdata(in: offset ..< offset + length))
            offset += length
        }
        return messages
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(slug: String, file: String)
        case malformedIndex(slug: String)

        var description: String {
            switch self {
            case .missing(let slug, let file):
                return "Fixture \(slug)/\(file) is missing — re-run scripts/capture-fixtures.sh"
            case .malformedIndex(let slug):
                return "Fixture \(slug)/obs-binary.index.json does not match obs-binary.bin"
            }
        }
    }
}
