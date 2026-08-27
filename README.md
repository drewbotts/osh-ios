# OSH iOS

An iOS sensor client for [OpenSensorHub](https://opensensorhub.org). It registers
the phone with an OSH node as an OGC **Connected Systems** system, registers one
datastream per enabled sensor, and streams observations to the node for as long
as a session runs.

It is a port of the `osh-android` sensor driver, and deliberately a faithful one:
the SWE Common schemas, definition URIs and observation encodings match the
Android driver field for field, so a node cannot tell an iPhone from an Android
phone except by the system UID.

---

## Supported sensors

| Output name              | Source                    | Fields (in schema order)               | Rate |
| ------------------------ | ------------------------- | -------------------------------------- | ---- |
| `gps_data`               | CoreLocation              | time, lat, lon, alt                    | 1 Hz |
| `quat_orientation_data`  | CoreMotion device motion  | time, qx, qy, qz, q0                   | configurable, default 10 Hz |
| `euler_orientation_data` | CoreMotion device motion  | time, heading, pitch, roll             | configurable, default 10 Hz |
| `barometer`              | CMAltimeter               | time, pressure (hPa), relativeAltitude | ~1 Hz, hardware-driven |
| `audio_level`            | AVAudioEngine tap         | time, rmsdB, peakdB                    | configurable, default 10 Hz |
| `camera0_H264`           | AVCaptureSession + VideoToolbox | time, img (H.264 frame)          | configurable, 1–25 fps |

Audio is **levels only** — no audio samples are recorded or transmitted.

Orientation uses `CMAttitudeReferenceFrame.xTrueNorthZVertical`, so headings are
referenced to true north rather than magnetic north. CoreMotion needs an
authorized, running `CLLocationManager` to resolve the local declination, so GPS
should be enabled for headings to mean what they say.

---

## How the data is modelled

### SWE Common

Every output describes itself with a `DataRecord` built from the same helpers
the Android driver uses (`GeoPosHelper`, `VideoCamHelper`). A record is a tree of
components; `SchemaWalker` flattens it into ordered **leaf paths** such as
`/time`, `/location/lat`, `/location/lon`.

That leaf order is the app's central contract. A sensor module emits a flat
`[Double]` in exactly that order, which is what lets the client serialise an
observation without naming a single field, and what lets `SchemaWalker` turn one
back into a `ParsedObservation` — a typed value per path — for the UI.

A `DataArray` is treated as **one** leaf, not a subtree. Its wire form is a
single `BinaryBlock` (a compressed frame), so descending into the million pixel
components it nominally describes would model a structure no observation ever
carries field by field.

### Connected Systems endpoints

Write side (`ConnectedSystemsClient`):

```
POST /systems                        → register this device, returns a system id
POST /systems/{id}/datastreams       → register one output, returns a datastream id
POST /datastreams/{id}/observations   → one observation (arrays are rejected)
GET  /systems/{id}                   → does the cached system id still exist?
GET  /datastreams/{id}               → does the cached datastream id still exist?
```

Read side (`ConnectedSystemsReadClient`):

```
GET /systems?limit=N
GET /systems/{id}
GET /systems/{id}/datastreams
GET /datastreams/{id}
GET /datastreams/{id}/schema?obsFormat=<mime>
```

Scalar observations are posted as `application/swe+json`; video frames as
`application/swe+binary` (8-byte big-endian timestamp, 4-byte length, then the
H.264 Annex-B frame).

### Ordered JSON

The node parses SWE JSON with a Gson streaming reader that requires `"type"` to
be the **first** key of every object. Swift dictionaries do not preserve
insertion order, so `ConnectedSystemsClient` and `SystemDescriptor` build their
JSON as ordered strings by hand. Unit tests scan the output and fail if any typed
object puts `type` anywhere but first — do not replace those builders with
`Codable` or `JSONSerialization`.

### Delivery

Scalar observations accumulate per datastream and flush every 250 ms, or
immediately at 50 records — but each observation is its own POST. The node's
swe+json binding reads exactly one record per request; a JSON array is rejected
with `Expected BEGIN_OBJECT but was BEGIN_ARRAY`, and the node then forwards
that 400 to an admin error page it denies, so the client sees only an opaque
302. Batching here is in *time*, not in payload.

A failed POST that looks like a transport or server problem sends the unsent
remainder to a 1,000-entry ring buffer and starts an exponential-backoff probe
(1 s → 30 s) until the node answers again, at which point the buffer drains. A
POST the node *rejects* (4xx, or a redirect, which this node uses for rejections)
drops that observation instead: resending it unchanged cannot succeed, and
because the ring buffer preserves order it would otherwise sit at the front
forever and block everything behind it.

Video never touches that path. A single H.264 frame is orders of magnitude
larger than a scalar record, so frames are posted directly, one at a time, with
an in-flight gate that drops a new frame rather than queueing a backlog of stale
ones on a slow link.

---

## Architecture

```
OSHiOS/                     the app's engine — no SwiftUI
├── API/                    write side of the Connected Systems API
│   ├── ConnectedSystemsClient      ordered-string JSON builders, POSTs
│   ├── ObservationPublisher        batching, ring buffer, backoff, status
│   ├── SystemRegistration          cached system id, scoped per server
│   └── DatastreamRegistration      cached datastream ids, scoped per server
├── Client/                 read side, plus the connection the UI holds
│   ├── ConnectedSystemsReadClient  listing, schemas, decoders, observations
│   ├── ReadModels                  SystemSummary, DatastreamSummary
│   ├── ObservationStream           live WebSocket subscription, decoded
│   ├── TimeSynchronizer            reorders observations across datastreams
│   ├── NodeConnection              one node: read client + write client
│   ├── NodeConnectionStore         rebuilds the connection when the server changes
│   ├── URLComponents+MediaType     percent-encodes "+" in a media-type query
│   └── NoRedirectDelegate          shared by both clients
├── SWE/                    the schema model and everything derived from it
│   ├── Model/                      DataComponent and friends, FieldPath,
│   │                               FieldValue, ParsedObservation, Observation,
│   │                               Constraints, BinaryEncoding
│   ├── Decode/                     reading a remote node's schemas and data
│   │   ├── SWESchemaDecoder        SWE JSON → DataComponent tree
│   │   ├── SWEParserTree           schema walked once into a reader tree
│   │   ├── TokenSource             the seam: one tree, several wire formats
│   │   ├── JSONTokenSource         swe+json, om+json, single records
│   │   ├── BinaryTokenSource       swe+binary, per the encoding's member table
│   │   ├── DatastreamDecoder       one datastream: schema + tree + decode()
│   │   └── BINARY_FORMAT.md        the verified byte layouts, and what is not
│   ├── SchemaWalker                leaf paths; values → ParsedObservation
│   └── LocationPaths               finds lat/lon/alt inside any Location record
├── OGC/                    schema *builders* (kept where the port put them)
│   ├── SWE/                        SWEConstants, GeoPosHelper, VideoCamHelper
│   └── SensorML/                   SystemDescriptor (POST /systems body)
├── Sensors/                one class per hardware output
├── Session/                SensorSession, SensorLiveState, TrackPoint,
│                           SessionActivityController
├── Storage/                AppSettingsStore, KeychainServerStore
├── Config/                 AppConfig, VideoConfig
└── Logging/                Log, OSHLogger, LogStore

OSHiOSShared/               compiled into both the app and the widget
└── SessionActivityAttributes       the Live Activity contract

OSHiOSWidgets/              widget extension: the Live Activity's views

osh-ios/                    the SwiftUI app
├── osh_iosApp              owns the three environment objects
├── ContentView             the tab bar
└── Views/
    ├── Live/               session bar + schema-driven SensorCard
    ├── Camera/             preview and encoder settings
    ├── Map/                TrackMapView (takes plain [TrackPoint])
    ├── Node/               server, registration, datastreams, systems
    ├── Logs/               in-app log tail
    └── Settings/           system name, servers, sensors, rates, behavior
```

### Reading a datastream

The decode path is a port of the parser architecture in osh-js: a schema is
walked **once** into a tree of reader nodes, and each message is decoded by
feeding that tree a token source that knows how to pull values out of one wire
format. The same tree serves JSON and binary, which is what keeps a datastream
rendering identically however it was fetched.

```swift
let decoder = try await connection.readClient.makeDecoder(datastreamId: id)

// archive
let page = try await connection.readClient.fetchObservations(
    datastreamId: id, latest: true, limit: 10, decoder: decoder)

// live
let stream = ObservationStream(connection: connection,
                               datastreamId: id,
                               decoder: decoder)
stream.start()
for await event in stream.events { … }
```

`fetchObservations` takes `latest:` because the node orders observations
ascending: a plain `limit: 10` returns the ten *oldest* records in the archive,
which is almost never what a caller asking for recent activity means.

`OSHiOS/SWE/Decode/BINARY_FORMAT.md` records the swe+binary layouts that were
verified against a live node, which fixture each was verified against, and the
one — the DataChoice selector — that could not be verified because no node
message exercising it exists.

### Two rules worth knowing before changing anything

**The UI is schema-driven.** `SensorCard` chooses its body from
`SensorCardKind.from(schema:)` and renders labels and units from the components
themselves. There is no `is GPSOutput` anywhere in the view layer. This is not
style: the planned data viewer renders datastreams read back from a node, which
have no local class at all, and it will reuse these components unchanged.

**A media type in a query string needs its "+" escaped.** Connected Systems
passes media types as query values — `?f=application/om+json` — and "+" is a
legal query character, so `URLComponents` leaves it alone and the servlet
container decodes it to a space. OpenSensorHub then answers 400 for a schema
request and 302 for an observations one, redirecting to an error page that
itself 401s, so nothing in the failure names the cause. Build those URLs with
`setQueryItemsEncodingPlus`.

**Registration ids are cached per server.** Each OSH node mints its own resource
ids, so `osh.<serverId>.systemId` and `osh.<serverId>.datastreamId.<output>` are
scoped by server UUID. A global key would hand a system id minted by node A to
node B and produce 404 churn on every switch.

---

## Building and running

Requirements: Xcode 16.4 or later, iOS 18.5 deployment target.

```bash
# Build for the simulator
xcodebuild -project osh-ios.xcodeproj -scheme osh-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Run the unit tests
xcodebuild -project osh-ios.xcodeproj -scheme osh-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:osh-iosTests test
```

The project uses Xcode's file-system-synchronized groups: a `.swift` file added
anywhere under `OSHiOS/`, `OSHiOSShared/`, `OSHiOSWidgets/`, `osh-ios/` or
`osh-iosTests/` joins the corresponding target automatically. There is no file
list to maintain in the project file.

The one exception is `osh-iosTests/Fixtures/`, which is a **folder reference**
so its directory structure survives into the test bundle — seven folders each
hold a `schema-json.json`, and a flat copy would collapse them onto one file.
Each fixture file is also listed as a membership exception so the synchronized
group does not claim it a second time and fail the build with "Multiple commands
produce …". `scripts/capture-fixtures.sh` regenerates that list, so adding a
fixture still needs no hand-editing of the project.

### Test fixtures and the live node

The unit tests run entirely from committed fixtures and never touch a network.
Tests that do talk to a node are skipped unless `OSH_NODE` is set — and
`xcodebuild` does not forward the host environment into the simulator, so the
variable needs a `TEST_RUNNER_` prefix on the way in:

```bash
TEST_RUNNER_OSH_NODE=http://host:8080/sensorhub/api \
  xcodebuild -project osh-ios.xcodeproj -scheme osh-ios \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:osh-iosTests test
```

Recapture the fixtures from a node with:

```bash
OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh survey
OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh capture
```

`survey` prints the node's systems, datastreams and component types without
writing anything; `capture` writes `osh-iosTests/Fixtures/` and is idempotent.
`OSH_TEST_USER` / `OSH_TEST_PASS` are used as Basic credentials when both are
set and are never written to any file. See `osh-iosTests/Fixtures/README.md` for
the layout and what each folder covers.

`SWIFT_STRICT_CONCURRENCY = complete` is on for every target. Keep it that way.

Sensor work needs a real device: the simulator has no camera, no barometer, no
device motion, and only a simulated location.

### Pointing it at an OSH node

1. **Settings → Servers → +**. Give it a label, the base API URL
   (`http://host:8181/sensorhub/api`), a username and a password. Credentials go
   to the Keychain; everything else to `UserDefaults`.
2. **Save**, then select the server on the **Node** tab.
3. **Test Connection** — a green check means the node answered and accepted the
   credentials.
4. **Live → Start Streaming**. The session registers the system, registers a
   datastream per enabled sensor, then starts posting.
5. The **Node** tab lists the datastreams the node now holds, with live sent /
   bytes / error counts beside each one that this session is feeding.

Plain `http://` to a LAN node works because App Transport Security allows
arbitrary loads for local addresses; a public node should use HTTPS.

---

## Known limitations

- **Background capture.** Only GPS survives the app leaving the foreground —
  the app declares the `location` background mode and enables background
  location updates when the user has granted when-in-use or always
  authorization. Camera, device motion and audio capture are suspended by
  platform policy, so those datastreams simply stop until the app is foreground
  again. The app never asks for Always authorization.
- **Heading needs empirical verification.** The Euler output converts
  `CMAttitude.yaw` to a compass heading (clockwise from true north, `[0, 360)`).
  The conversion is unit-tested, but the *sign and origin* against a real
  compass have not been verified on a device, and CoreMotion silently falls back
  to magnetic north without a location fix. Treat headings as unconfirmed until
  someone checks them against a known bearing outdoors.
- **Every video frame is a keyframe.** The encoder forces
  `MaxKeyFrameInterval = 1` so each observation is independently decodable — the
  node stores frames as discrete observations with no GOP context. The cost is a
  much higher bitrate than a normal GOP structure would need.
- **The decoded schema browser is only reachable for this device's own
  datastreams.** `DatastreamDetailView` now shows a decoded schema tree and the
  last ten observations, but the Node tab reaches it only from the datastreams
  this device registered — the "Browse systems on node" list is still read-only
  rows with no drill-down. The decoder handles every datastream on the reference
  node; the navigation to them does not exist yet.
- **The server form requires a username** even against a node configured for
  anonymous access, so such a node has to be given throwaway credentials.
- **Live Activity and camera preview are device-only.** Both are wired up but
  cannot be exercised meaningfully in the simulator.
- **Six tabs means a "More" tab.** iOS collapses tabs past the fifth on iPhone,
  so Logs and Settings live behind **More**.

---

## Roadmap

- **Viewer.** Render observations fetched from a node using the same
  `SensorCard` and `TrackMapView` components the live tabs use. The pieces are
  already in place: `ParsedObservation`, `SchemaWalker`, `LocationPaths` and
  `TrackPoint` know nothing about local sensors.
- **SWE schema decoding**, so a remote datastream produces a real `DataRecord`
  instead of a JSON blob.
- **MJPEG** output alongside H.264, for clients that cannot decode a bare
  Annex-B stream.
- **Commands**, so a node can drive the phone rather than only listen to it.
- **Garmin** wearable sensors as an additional set of outputs.
