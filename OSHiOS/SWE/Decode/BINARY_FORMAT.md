# application/swe+binary — verified wire layout

Every row below was checked byte-for-byte against messages captured from a live
OpenSensorHub node (`scripts/capture-fixtures.sh`), not inferred from the SWE
Common documents. Where the two disagree, this table records what the node
actually does.

Reproduce any row with the fixtures in `osh-iosTests/Fixtures/`; the tests in
`BinaryFormatTests.swift` assert them.

## Framing

A message is a bare concatenation of field values in schema order. Nothing in
the stream names a field or delimits a record, so the schema and its
`recordEncoding` member table are the only things that make the bytes readable.
Multiple records concatenate with no separator — which is why
`obs-binary.index.json` records each message's length.

- **Byte order**: from `recordEncoding.byteOrder`. Every stream on the reference
  node is `bigEndian`, which is also the SWE Common default when the key is
  absent.
- **byteEncoding**: `raw` on every stream observed. `base64` is handled by
  base64-decoding the whole message once before any field is read.

## Scalar types

| SWE dataType | Byte layout | Verified against |
|---|---|---|
| `double` | 8 bytes, IEEE 754 binary64 | `weather`, `gps`, `ais-vessel-location`, `video-mjpeg` — timestamps and every `/location/*` coordinate matched the swe+json values exactly |
| `float32` | 4 bytes, IEEE 754 binary32 | `spectrum-array` — 2048 values matched swe+json to float precision |
| `signedInt` | 4 bytes, two's complement | `ais-vessel-location` `/repeat`, `/utcSecond`; `spectrum-array` `/freq_count` = 1024 |
| `signedShort` | 2 bytes, two's complement | **not exercised** — no fixture stream declares one |
| `signedByte` | 1 byte, two's complement | **not exercised** |
| `unsignedInt` / `unsignedShort` / `unsignedByte` | 4 / 2 / 1 bytes, unsigned | **not exercised** |
| `signedLong` / `unsignedLong` | 8 bytes | **not exercised** |
| `boolean` | 1 byte, non-zero is true | `ais-vessel-location` `/positionAccuracy`, `/raim` — both `00`, matching `false` in swe+json |
| `string-utf-8` | **2-byte big-endian length, then that many bytes** | `spectrum-array` `/channel` = `00 03 63 68 30` → `"ch0"`; `ais-vessel-location` 6 text fields; KrakenSDR command `00 04 32 39 2e 37` → `"29.7"` |

Note the spelling: the node writes **`string-utf-8`**, never `utf8String`.
`SWEDataType.from(uriSuffix:)` matches on the URI's last path component so both
a bare suffix and a full URI resolve.

### Text encoding detail

The 2-byte length prefix is `java.io.DataOutputStream.writeUTF` framing, and the
payload is therefore Java's *modified* UTF-8, which differs from standard UTF-8
in exactly two places: NUL is written `C0 80`, and a character outside the BMP is
written as its two surrogates encoded separately (CESU-8).

Every string in every captured fixture is ASCII, so **the modified-UTF-8
distinction is not exercised by any fixture**. `BinaryTokenSource` decodes as
standard UTF-8 first and falls back to a modified-UTF-8 decoder only when that
fails, which is correct for both forms and cannot regress the ASCII case.

## Blocks

| Member kind | Byte layout | Verified against |
|---|---|---|
| `Block` (no `byteLength`) | 4-byte big-endian length, then that many opaque bytes | `video-mjpeg` — `00 03 e2 87` = 254 599, and 12 + 254 599 = 254 611 = the exact WebSocket message length |
| `Block` (`byteLength` declared) | exactly `byteLength` bytes, no prefix | **not exercised** — no fixture declares one |
| `paddingBytes-before` / `-after` | skipped before/after the payload | **not exercised** |

The `video-mjpeg` payload begins `FF D8` (JPEG SOI) and ends `FF D9` (JPEG EOI),
confirming the length is the payload's own and excludes the prefix.

This layout is the exact inverse of
`ConnectedSystemsClient.buildBinaryObsBody`, which writes an 8-byte big-endian
double timestamp, a 4-byte big-endian `UInt32` length, then the frame.

## DataArray

A node writes **one** encoding member for a DataArray, keyed by the element
*type's* name rather than one member per index:

```
"ref": "/frequency_axis/frequency"    ← one member, describes every element
```

Values are decoded to indexed paths (`/frequency_axis/0/frequency` …), so
`DecodedBinaryEncoding.member(for:)` strips index components before matching.

A variable-size array's length is not in the encoding. It comes from a `Count`
field elsewhere in the same record, referenced by `elementCount: {"href": "#id"}`
and read from the stream earlier in the same message. Verified against
`spectrum-array`: `/freq_count` = 1024, followed by exactly 1024 float32s, twice,
consuming all 8 213 bytes with none left over.

## DataChoice — NOT VERIFIED

| Element | Assumed layout | Status |
|---|---|---|
| Selector | 1 byte, the selected item's index | **UNVERIFIED — no fixture exists** |
| Selected item | the item's own fields, in schema order | unverified |

The reference node exposes exactly one DataChoice — the Axis PTZ control
stream's `paramsSchema` — and it has **zero archived messages**, so no real bytes
were available. Its binary encoding is also informative by omission:

```
members: /pan, /tilt, /zoom, /rpan, /rtilt, /rzoom, /preset,
         /ptzPos/pan, /ptzPos/tilt, /ptzPos/zoom
```

There is **no member for the selector itself**, only for the items — so the
selector's width cannot be read from the member table either, and
`BinaryTokenSource` falls back to the one-byte assumption stated in this pass's
spec and used by osh-core's binary writer.

If a node is ever observed to disagree, the node wins: change
`readChoiceSelector` and this table together.

## Control-stream refs are relative

A control stream's `paramsEncoding` writes refs relative to the `paramsSchema`
component (`/pan`), not to a record wrapping it. `SWESchemaDecoder` wraps a
non-record top level in a single-field record and rebases the member refs under
that field's name so the two keep addressing the same paths.
