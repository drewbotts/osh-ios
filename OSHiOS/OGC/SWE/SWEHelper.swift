import Foundation

// MARK: - OGC SWE Common property URI helpers
//
// The schema *types* these helpers build live in OSHiOS/SWE/Model/; this file
// and its siblings (GeoPosHelper, VideoCamHelper) are the builders that
// assemble them into the specific records the Android driver registers.

enum SWEConstants {
    static let propertyBaseURI = "http://sensorml.com/ont/swe/property/"
    static let refFrame_WGS84_HAE = "http://www.opengis.net/def/crs/EPSG/0/4979"
    static let refFrame_4326     = "http://www.opengis.net/def/crs/EPSG/0/4326"
    static let refFrame_ENU      = "http://www.opengis.net/def/crs/OGC/0/ENU"
    static let defCoef           = "http://sensorml.com/ont/swe/property/Coefficient"

    static func propertyURI(_ name: String) -> String {
        propertyBaseURI + name
    }
}
