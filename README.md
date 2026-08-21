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
│   ├── ConnectedSystemsReadClient  listing and fetching, tolerant decoding
│   ├── ReadModels                  SystemSummary, DatastreamSummary
│   ├── NodeConnection              one node: read client + write client
│   ├── NodeConnectionStore         rebuilds the connection when the server changes
│   └── NoRedirectDelegate          shared by both clients
├── SWE/                    the schema model and everything derived from it
│   ├── Model/                      DataComponent and friends, FieldPath,
│   │                               FieldValue, ParsedObservation, Observation
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

### Two rules worth knowing before changing anything

**The UI is schema-driven.** `SensorCard` chooses its body from
`SensorCardKind.from(schema:)` and renders labels and units from the components
themselves. There is no `is GPSOutput` anywhere in the view layer. This is not
style: the planned data viewer renders datastreams read back from a node, which
have no local class at all, and it will reuse these components unchanged.

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
- **Schemas are shown raw.** The Node tab pretty-prints a datastream's schema
  document; it does not decode it. Nothing in the app can yet render a remote
  datastream's *observations*.
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
