import Foundation

// MARK: - VideoCamHelper
//
// Builds the SWE DataRecord schema and BinaryEncoding for compressed video output,
// mirroring VideoCamHelper.newVideoOutputCODEC() from osh-addons.
//
// Android calls newVideoFrameRGB(name, width, height) which creates:
//   DataRecord (VideoFrame)
//   ├─ Time  "time"
//   └─ DataArray "img" (RasterImage, height rows × width pixels × RGB bytes)
//
// Then wraps it with a BinaryEncoding:
//   BinaryComponent ref="/time"  → DataType.DOUBLE  (8-byte big-endian timestamp)
//   BinaryBlock     ref="/img"   → compression = codec (H264 or JPEG)
//
// This means the logical schema fully describes the pixel structure, while the
// actual wire format compresses the entire img DataArray into a single binary block.
//
// obsFormat: "application/swe+binary"
// Observations: 8-byte big-endian Double timestamp + compressed frame bytes
//
// The DataArray dimensions must match the configured capture resolution so the
// server knows the frame size for any downstream processing.

enum VideoCamHelper {
    static let DEF_VIDEOFRAME    = SWEConstants.propertyURI("VideoFrame")
    static let DEF_RASTERIMAGE   = SWEConstants.propertyURI("RasterImage")
    static let DEF_GRID_HEIGHT   = SWEConstants.propertyURI("GridHeight")
    static let DEF_GRID_WIDTH    = SWEConstants.propertyURI("GridWidth")
    static let DEF_RED_CHANNEL   = SWEConstants.propertyURI("RedChannel")
    static let DEF_GREEN_CHANNEL = SWEConstants.propertyURI("GreenChannel")
    static let DEF_BLUE_CHANNEL  = SWEConstants.propertyURI("BlueChannel")

    static func newVideoOutputCODEC(
        name: String,
        width: Int,
        height: Int,
        codec: String
    ) -> (schema: DataRecord, encoding: BinaryEncoding) {

        // Pixel DataRecord: red / green / blue Count fields
        let pixelRecord = DataRecord(
            definition: nil,
            label: nil,
            name: "pixel",
            fields: [
                DataField(name: "red",   component: SWECount(definition: DEF_RED_CHANNEL)),
                DataField(name: "green", component: SWECount(definition: DEF_GREEN_CHANNEL)),
                DataField(name: "blue",  component: SWECount(definition: DEF_BLUE_CHANNEL))
            ]
        )

        // Inner DataArray: one row of `width` pixels
        let rowArray = SWEDataArray(
            definition: nil,
            label: nil,
            elementCount: SWECount(
                definition: DEF_GRID_WIDTH,
                axisID: "X",
                value: width
            ),
            elementTypeName: "pixel",
            elementType: pixelRecord
        )

        // Outer DataArray: `height` rows
        let imgArray = SWEDataArray(
            definition: DEF_RASTERIMAGE,
            label: nil,
            elementCount: SWECount(
                definition: DEF_GRID_HEIGHT,
                axisID: "Y",
                value: height
            ),
            elementTypeName: "row",
            elementType: rowArray
        )

        // Root DataRecord: time + img  (mirrors Android newVideoFrameRGB + wrapWithTimeStamp)
        let record = DataRecord(
            definition: DEF_VIDEOFRAME,
            label: "Video Frame",
            name: name,
            fields: [
                DataField(name: "time", component: TimeStamp()),
                DataField(name: "img",  component: imgArray)
            ]
        )

        // BinaryEncoding: scalar double for time + BinaryBlock for the compressed img
        // (mirrors Android: BinaryComponent "/time" DOUBLE + BinaryBlock "/img" compression=codec)
        let enc = BinaryEncoding(fields: [
            BinaryFieldEncoding(ref: "/time", type: .scalar(.double)),
            BinaryFieldEncoding(ref: "/img",  type: .block(compression: codec))
        ])

        return (record, enc)
    }
}
