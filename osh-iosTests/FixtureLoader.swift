import Foundation

// MARK: - FixtureLoader
//
// Reads the captured node documents under osh-iosTests/Fixtures.
//
// The tree is a FOLDER REFERENCE in the test target, so it is copied into the
// bundle with its directory structure intact and adding a fixture needs no
// project edit beyond the membership list that scripts/capture-fixtures.sh
// regenerates. That structure is the point: every folder holds its own
// "schema-json.json", and a flat copy would collapse them onto one file.
//
// The bundle copy is preferred, with the source tree as a fallback so the
// fixtures stay readable when a test runs outside a built bundle.

enum FixtureLoader {

    /// Fixture slugs, one per captured datastream or control stream.
    enum Slug: String, CaseIterable {
        case weather            // plain scalar record: Quantity + Count + Text
        case aisVesselLocation  = "ais-vessel-location"  // Boolean/Category/Text/Vector/nilValues
        case spectrumArray      = "spectrum-array"       // variable-size DataArray via href
        case videoMJPEG         = "video-mjpeg"          // nested DataArray + BinaryBlock
        case gps                                          // Time + Vector, as this app writes
        case krakenSettings     = "kraken-settings"      // deeply nested DataRecord
        case krakenDOA          = "kraken-doa"            // direction finding: LOB + confidence
        case choicePTZControl   = "choice-ptz-control"   // DataChoice (control stream)
        case lrfTarget          = "lrf-target"           // a designated target point
        case lrfRange           = "lrf-range"            // azimuth with no location vector
    }

    /// The fixture tree: the copy inside the test bundle when there is one,
    /// otherwise the one in the source tree.
    static let root: URL = {
        let bundled = Bundle(for: BundleAnchor.self)
            .bundleURL.appendingPathComponent("Fixtures", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }()

    /// Exists only to give `Bundle(for:)` a class inside the test bundle.
    private final class BundleAnchor {}

    static func directory(_ slug: Slug) -> URL {
        root.appendingPathComponent(slug.rawValue, isDirectory: true)
    }

    /// Fixture folders actually present on disk, so a test can assert over what
    /// was captured rather than over a hardcoded list.
    static var presentSlugs: [Slug] {
        Slug.allCases.filter {
            FileManager.default.fileExists(atPath: directory($0).path)
        }
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
