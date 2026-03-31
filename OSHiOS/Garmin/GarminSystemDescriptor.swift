import Foundation

// MARK: - GarminSystemDescriptor
//
// Builds the SensorML-JSON body for registering a Garmin wearable as a
// child system (subsystem) of the phone system.
//
// POST /api/systems/{phoneSystemId}/subsystems
//
// UID pattern:  "urn:osh:sensor:garmin:{unitID}"
// XMLID:        "GARMIN_{unitID}"
//
// The JSON format follows the same key-ordering rules as SystemDescriptor:
// "type" must be the FIRST key in every object (server streaming parser requirement).

struct GarminSystemDescriptor {

    static let uidPrefix = "urn:osh:sensor:garmin"

    let uniqueID: String
    let xmlID: String
    let name: String
    let localFrameURI: String

    /// - Parameters:
    ///   - unitID: Garmin device unit ID (an integer uniquely identifying the hardware).
    ///   - deviceName: Human-readable display name (e.g. "Forerunner 255").
    init(unitID: UInt32, deviceName: String) {
        let uid = "\(Self.uidPrefix):\(unitID)"
        self.uniqueID     = uid
        self.xmlID        = "GARMIN_\(unitID)"
        self.name         = deviceName
        self.localFrameURI = uid + "#LOCAL_FRAME"
    }

    // MARK: - JSON serialisation

    func toJSONData() throws -> Data {
        let json = buildJSON()
        guard let data = json.data(using: .utf8) else {
            throw GarminDescriptorError.encodingFailed
        }
        return data
    }

    // MARK: - JSON builder

    private func buildJSON() -> String {
        var s = "{"

        s += kv("type", "PhysicalSystem")
        s += "," + kv("id",       xmlID)
        s += "," + kv("uniqueId", uniqueID)
        s += "," + kv("label",    name)

        // identifiers
        s += ","
        s += q("identifiers") + ":["
        s += "{" + kv("label", "Short Name")  + "," + kv("value", name)     + "},"
        s += "{" + kv("label", "Unique ID")   + "," + kv("value", uniqueID) + "}"
        s += "]"

        // localReferenceFrames — Garmin uses wrist-frame axes
        s += ","
        s += q("localReferenceFrames") + ":["
        s += "{"
        s +=   kv("id", "LOCAL_FRAME")
        s +=   "," + kv("origin", "Center of the wrist-worn device")
        s +=   "," + q("axes") + ":["
        s +=     "{" + kv("name", "x") + "," + kv("description", "Along the arm toward the hand") + "},"
        s +=     "{" + kv("name", "y") + "," + kv("description", "Perpendicular to the arm, toward the thumb side") + "},"
        s +=     "{" + kv("name", "z") + "," + kv("description", "Normal to the watch face, pointing away from wrist") + "}"
        s +=   "]"
        s += "}"
        s += "]"

        s += "}"
        return s
    }

    // MARK: - Helpers

    private func q(_ key: String) -> String { "\"\(key)\"" }

    private func kv(_ key: String, _ value: String) -> String {
        "\(q(key)):\(q(jsonEscape(value)))"
    }

    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Errors

enum GarminDescriptorError: Error {
    case encodingFailed
}
