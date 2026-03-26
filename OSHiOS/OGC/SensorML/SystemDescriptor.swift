import Foundation
import UIKit

// MARK: - SystemDescriptor
//
// Builds the SensorML-JSON body for POST /api/systems.
//
// Format derived directly from SMLJsonBindings.java (writeDescribedObject / writePhysicalSystemProperties):
//
//   writeDescribedObject        → { "type": "PhysicalSystem", ...properties }
//   writeDescribedObjectProperties →
//     writeGmlProperties        → id, uniqueId, label, description
//     writeIdentifiers          → "identifiers": [ { label, value }, ... ]
//   writePhysicalProcessProperties →
//     writeLocalFrames          → "localReferenceFrames": [ { id, label, origin, "axes": [...] } ]
//
// IMPORTANT: The server's JSON parser (Gson streaming) requires "type" to be the FIRST key
// in every object.  Swift Dictionary does not guarantee ordering, so we build the JSON
// string directly instead of using JSONSerialization.
//
// iOS UID scheme mirrors Android:
//   Android: "urn:osh:android:{ANDROID_ID}"
//   iOS:     "urn:osh:ios:{UIDevice.identifierForVendor}"

struct SystemDescriptor {
    static let uidPrefix = "urn:osh:ios"

    let uniqueID: String
    let xmlID: String
    let name: String
    let description: String
    let localFrameURI: String

    init(config: AppConfig) {
        let deviceUUID = UIDevice.current.identifierForVendor?.uuidString.lowercased()
            ?? UUID().uuidString.lowercased()

        var uid = "\(Self.uidPrefix):\(deviceUUID)"
        if !config.uidExtension.isEmpty {
            uid += ":\(config.uidExtension)"
        }

        self.uniqueID     = uid
        self.xmlID        = "IOS_SENSORS_\(deviceUUID.replacingOccurrences(of: "-", with: "_").uppercased())"
        self.localFrameURI = uid + "#LOCAL_FRAME"
        self.name         = config.deviceName.isEmpty ? UIDevice.current.model : config.deviceName
        self.description  = config.runDescription
    }

    // MARK: - JSON serialisation

    /// Returns the SensorML-JSON Data for POST /api/systems.
    ///
    /// Keys are written in the order the server's streaming parser expects:
    ///   - "type" is always first in every object
    ///   - matches writeDescribedObject / writePhysicalSystemProperties ordering in SMLJsonBindings.java
    func toJSONData() throws -> Data {
        let json = buildJSON()
        guard let data = json.data(using: .utf8) else {
            throw SystemDescriptorError.encodingFailed
        }
        return data
    }

    // MARK: - JSON builder

    private func buildJSON() -> String {
        var s = "{"

        // type must be first (SMLJsonBindings.writeDescribedObject → writeTypeAndName)
        s += kv("type", "PhysicalSystem")

        // writeGmlProperties: id, uniqueId, label, description
        s += "," + kv("id",          xmlID)
        s += "," + kv("uniqueId",    uniqueID)
        s += "," + kv("label",       name)
        if !description.isEmpty {
            s += "," + kv("description", description)
        }

        // writeIdentifiers → "identifiers": [ { label, value } ]
        // writeTerm writes: definition?, codeSpace?, label, value  (no "type")
        s += ","
        s += q("identifiers") + ":["
        s += "{" + kv("label", "Short Name") + "," + kv("value", name) + "},"
        s += "{" + kv("label", "Unique ID")  + "," + kv("value", uniqueID) + "}"
        s += "]"

        // writePhysicalProcessProperties → writeLocalFrames
        // Key is "localReferenceFrames" (plural)
        // Each frame: writeAbstractSWEIdentifiableProperties (id, label) + origin + "axes"
        // Axis objects: { "name": ..., "description": ... }  (no "type")
        s += ","
        s += q("localReferenceFrames") + ":["
        s += "{"
        s +=   kv("id", "LOCAL_FRAME")
        s +=   "," + kv("origin", "Center of the device screen")
        s +=   "," + q("axes") + ":["
        s +=     "{" + kv("name", "x") + "," + kv("description", "The X axis is in the plane of the screen and points to the right") + "},"
        s +=     "{" + kv("name", "y") + "," + kv("description", "The Y axis is in the plane of the screen and points up") + "},"
        s +=     "{" + kv("name", "z") + "," + kv("description", "The Z axis points towards the outside of the front face of the screen") + "}"
        s +=   "]"
        s += "}"
        s += "]"

        s += "}"
        return s
    }

    // MARK: - Helpers

    /// Quoted JSON key.
    private func q(_ key: String) -> String { "\"\(key)\"" }

    /// Key-value pair with JSON-escaped string value.
    private func kv(_ key: String, _ value: String) -> String {
        "\(q(key)):\(q(jsonEscape(value)))"
    }

    /// Minimal JSON string escaping.
    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Errors

enum SystemDescriptorError: Error {
    case encodingFailed
}
