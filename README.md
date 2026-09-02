# OSH iOS

An iOS client for [OpenSensorHub](https://opensensorhub.org). It registers the
phone with an OSH node as an OGC **Connected Systems** system, registers one
datastream per enabled sensor, and streams observations to the node for as long
as a session runs — and it reads the same node back: every system it holds on
one map, every camera on one wall, and a pan/tilt/zoom camera driven from a
D-pad over its own picture.

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
GET /systems/{id}/controlstreams
GET /datastreams/{id}
GET /datastreams/{id}/schema?obsFormat=<mime>
GET /controlstreams/{id}/schema?commandFormat=application/swe%2Bjson
GET /controlstreams/{id}/commands?limit=N
```

Command side (`CommandClient`):

```
POST /controlstreams/{id}/commands   → one command, returns a status report
```

Every request carries an explicit `Accept`. Without it the reference node serves
its HTML admin console for these paths and that console demands a login the API
does not — a 401 from an OSH node is very often a missing `Accept` header rather
than a missing password.

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
│   ├── CommandClient               POSTs commands; ordered-string bodies
│   ├── CommandBody                 the command JSON, built key by key
│   ├── COMMANDS.md                 the verified command envelope, captured live
│   ├── NodeConnection              one node: read + write + command clients
│   ├── NodeConnectionStore         rebuilds the connection when the server changes
│   ├── NetworkPathObserver         WiFi or cellular, for video autoplay
│   ├── URLComponents+MediaType     percent-encodes "+" in a media-type query
│   ├── ISO8601DateFormatter+Flexible  parses both of the node's timestamp forms
│   └── NoRedirectDelegate          shared by all three clients
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
│   └── LocationPaths               finds lat/lon/alt at any depth, plus heading
├── Viewer/                 what a datastream *is*, and how to watch one
│   ├── DatastreamRole              schema → role: location, bearing, chart, …
│   ├── EntityKey                   which field names the thing an obs is about
│   ├── RemoteSystem                a node system resolved far enough to draw
│   ├── RemoteSystemLoader          actor: schemas concurrently, 5-min cache
│   ├── SystemLiveSession           one system watched live, entity-bucketed
│   ├── SystemActivity              live / stale / offline, and the thresholds
│   ├── ActivityTracker             one freshness picture, shared by every screen
│   ├── Control/PTZCapability       command schema → pan/tilt/zoom, or nothing
│   ├── SystemGlyph                 role → SF Symbol and tint, one table for
│   │                               every screen
│   ├── BearingGeometry             geodesic LOB endpoints; BearingStyle
│   ├── WaterfallBuffer             SDR waterfall pixels, no SwiftUI
│   ├── Video/MJPEGDecoder          JPEG blocks → CGImage, off the main actor
│   └── ROLES.md                    the inference rules, and how to extend them
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
    ├── Camera/             DeviceCameraView: preview and encoder settings,
    │                       pushed from the video wall's first tile
    ├── Video/              the video wall: VideoWallView/Model, the full-screen
    │                       NodeVideoPlayerView with its PTZ overlay
    ├── Browser/            SystemsTabView (the systems surface),
    │                       SystemDashboardView, DatastreamCard,
    │                       ControlStreamCard — the role-driven card grid
    ├── Map/                the COP: COPMapView/Model/Annotations, DeviceLayer,
    │                       MarkerClustering
    ├── Node/               DeviceDatastreamsView, DatastreamDetailView,
    │                       SchemaTreeView — this device's side of the node
    ├── Shared/             FieldRowsView, LocationSummaryView, VideoBadgeView,
    │                       SystemMapView, MarkerView, ClusterMarkerView,
    │                       ActivityDot,
    │                       PTZControlView, HeadingDialView, WaterfallView,
    │                       MJPEGView
    ├── Logs/               in-app log tail
    └── Settings/           system name, servers, sensors, rates, behavior
```

### The three surfaces

Six tabs — **Live, Video, Map, Systems, Logs, Settings** — and three of them are
the same node seen three ways.

**Map is the common operating picture.** One map, not two: this device's track
and fix are drawn beside every positioned system on the node, with bearing lines
and multi-entity markers. There is no This Device / Node switch, because the
value of a node is that a phone's track and a direction finder's line of bearing
are *one* picture. A toolbar menu toggles the layers — this device, node
systems, tracks, bearing lines, labels — and the live-updates switch, all
persisted in `AppConfig.mapLayers`. Tapping a marker opens the system's cards
and a link to its dashboard; tapping this device's marker follows it.

**Video is the wall.** Every video datastream on the node, two up in portrait
and three across in landscape, with this device's own camera preview as the
first tile. At most four MJPEG streams play at once — the fifth pauses the one
that has been playing longest — and autoplay defaults to WiFi-only, checked
through `NWPathMonitor`. Tapping a tile opens a full-screen player; if that
camera has a recognised PTZ control stream, the D-pad appears over the picture.

**Systems is the list.** Server picker, connectivity, this device's
registration and the publisher counters at the top; every system below,
sorted live-first and filterable by All / Live only / With position / With video
/ With controls. Rows open `SystemDashboardView`, which is still the per-system
drill-down and is no longer the only way to see anything.

### System activity

Every surface draws the same status dot, from one place.

| State | Meaning |
|---|---|
| 🟢 live | newest observation ≤ 5 min old |
| 🟠 stale | ≤ 30 min |
| 🔴 offline | > 30 min, or nothing ever observed |

The thresholds live in `ActivityThresholds` and nowhere else — they will become
a setting. Freshness is derived in three layers: `DatastreamSummary`'s reported
`phenomenonTimeRange` classifies a whole node without opening a stream (a range
ending in `now` or `latest` means data is flowing, so it counts as live);
observations arriving through any `SystemLiveSession` promote their system in
real time; and this device is live by definition while its session streams. A
30-second timer re-evaluates everything, because a system that goes quiet
produces nothing to notice it with.

### Commanding

`PTZCapability.detect` reads a control stream's parameters schema and decides
whether it describes a pan/tilt/zoom camera — from definitions first
(`RelativePan`, `Tilt`, `ZoomFactor`, `CameraPresetPositionName`) and item names
second, exactly as `DatastreamRole` reads an observation schema. A schema with
neither a relative nor an absolute pan/tilt *pair* is not a PTZ camera, and its
dashboard card shows the decoded parameter tree read-only instead of a joystick
that would do nothing.

The command envelope was determined empirically against the reference node and
is documented in full, with captured requests and responses, in
`OSHiOS/Client/COMMANDS.md`:

```
POST /controlstreams/{id}/commands
Content-Type: application/json

{"parameters":{"rpan":3.0}}
→ 200 {"command@id":"…","reportTime":"…","statusCode":"COMPLETED",
       "executionTime":["…","…"]}
```

The parameters schema is a `DataChoice`, so exactly one item is the sole key of
`parameters`. `issueTime` is optional and comes first when present. Bodies are
built as ordered strings by `CommandBody`, never by `JSONEncoder`: the node
reads a record's fields in the order its schema declares them and answers 400
for anything else — `{"ptzPos":{"pan":0.0}}` returns *"Expected a name but was
END_OBJECT at $.parameters.ptzPos.pan"*.

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

`latest:` is not the same as "the newest records this datastream holds", and the
difference matters. On the reference node `phenomenonTime=latest` means *the
current value of a live stream*, so a datastream that has stopped publishing
answers with an empty collection however full its archive is — which is exactly
the state a direction-finding output is in between detections. Use
`fetchMostRecent(datastream:limit:decoder:)` when you want the newest records
whatever their age: it takes the fast path for an open stream and otherwise
queries the tail of the datastream's own reported time range, widening the
window until records turn up.

`OSHiOS/SWE/Decode/BINARY_FORMAT.md` records the swe+binary layouts that were
verified against a live node, which fixture each was verified against, and the
one — the DataChoice selector — that could not be verified because no node
message exercising it exists.

### Viewing a system

The viewer matches systems to visualisations **purely from their data
structures**. Nothing asks which driver wrote a stream: a card, a marker, a dial
or a waterfall is chosen because the record carries a location vector, a
quaternion, an azimuth or a numeric array. That is what lets the app render a
KrakenSDR it has never seen with the same code that renders this phone.

```swift
let loader = RemoteSystemLoader()
guard case .success(let system) = await loader.load(systemId: id,
                                                    using: connection.readClient,
                                                    serverId: server.id) else { return }

let session = SystemLiveSession(system: system, connection: connection)
session.start()                 // everything but video, capped at 8 streams
…
session.stop()
```

**Roles.** `DatastreamRoleInference.role(schema:encoding:datastreamName:)`
returns one of `.location`, `.orientation`, `.bearing`, `.video`, `.chart`,
`.timeseries`, `.status` or `.generic`, carrying the field paths the card needs.
`.generic` is a fallback that always renders, so no stream on any node is
unviewable. The ordered rules, the keyword lists and how to add to either are in
`OSHiOS/Viewer/ROLES.md`.

**Entity keys.** One AIS datastream carries every vessel in range, so
"the latest observation" is not a position — it is whichever ship last
transmitted. `EntityKeyInference` finds the identifying field (`/mmsi`) and
`SystemLiveSession` buckets observations by its value; a single-entity stream
uses `""` as its one bucket. Only `.location` streams are grouped.

**Embedded positions.** `RemoteDatastream.embeddedPosition` is computed for
every datastream whose record holds a location vector at any depth, and is nil
when the role is already `.location`. This is how a system with no position
output still lands on the map: KrakenSDR states where it stands inside its
settings record, at `/stationConfig/location`, with the array heading beside it.

**PositionKind.** `.live` (a location datastream) beats `.reported` (an embedded
position) beats `.deployed` (the system resource's own geometry). The marker
looks different for each, because "we are tracking this" and "someone typed this
in once" should not read the same. A deployed marker never rotates.

**Markers.** `MarkerView` draws a role-tinted disc with the system's glyph, an
`ActivityDot` fused to its top right, and — when there is a heading — an
arrowhead travelling round a ring *outside* the disc. The glyph itself never
rotates: the previous marker turned the whole disc, which drew a camera pointing
south-west upside down. Freshness arrives as a value rather than as an
`@EnvironmentObject`, because a hundred markers each observing the tracker would
redraw the whole map whenever any one system changed colour.

**SystemLiveSession.** One `ObservationStream` per selected datastream, all of
them routed through one `TimeSynchronizer` so a video frame and the fix taken at
the same instant are published together. History rings at 300 per datastream;
video blocks go to the MJPEG decoder rather than into a ring. It bootstraps from
the archive on start — half an hour for positions and scalar series, a single
most-recent record for bearings and embedded positions, because a
direction-finding output emits only on detection and its last LOB may be months
old and still the thing to show.

**Lines of bearing persist.** A LOB fades to 30% after a minute and is never
removed, and every card and sheet showing one says when it was observed. Its
endpoint is computed geodesically (`BearingGeometry.destination`) and never as a
screen-space rotation: at 60° north a Mercator projection turns a 45° bearing
into a 63° line.

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

Point the live suite at an `https://` node with a self-signed certificate by
adding `TEST_RUNNER_OSH_TRUST_SELF_SIGNED=1`, which is the same choice the
per-server toggle makes in the UI:

```bash
TEST_RUNNER_OSH_NODE=https://host:8443/sensorhub/api \
TEST_RUNNER_OSH_TRUST_SELF_SIGNED=1 \
  xcodebuild -project osh-ios.xcodeproj -scheme osh-ios \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:osh-iosTests/LiveNodeTests test
```

Leaving it out against such a node is a useful check in itself: the suite should
fail with `-1202` and "Certificate not trusted", which is what a user sees.

`survey` prints the node's systems, datastreams and component types without
writing anything; `capture` writes `osh-iosTests/Fixtures/` and is idempotent.
`OSH_TEST_USER` / `OSH_TEST_PASS` are used as Basic credentials when both are
set and are never written to any file. See `osh-iosTests/Fixtures/README.md` for
the layout and what each folder covers.

`LiveCommandTests` moves a real camera, so it needs a second, explicit opt-in on
top of `OSH_NODE`. It pans three degrees, checks the camera's own position
output moved, and pans back — issuing the return even when an assertion in
between fails, so a red test never leaves a camera somewhere nobody asked for:

```bash
TEST_RUNNER_OSH_NODE=http://host:8080/sensorhub/api \
TEST_RUNNER_OSH_ALLOW_COMMANDS=1 \
  xcodebuild -project osh-ios.xcodeproj -scheme osh-ios \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:osh-iosTests/LiveCommandTests test
```

`SWIFT_STRICT_CONCURRENCY = complete` is on for every target. Keep it that way.

Sensor work needs a real device: the simulator has no camera, no barometer, no
device motion, and only a simulated location.

### Pointing it at an OSH node

1. **Settings → Servers → +**. Give it a label, the base API URL
   (`http://host:8181/sensorhub/api`), a username and a password. Credentials go
   to the Keychain; everything else to `UserDefaults`.
2. **Save**, then select the server on the **Systems** tab.
3. **Test Connection** — a green check means the node answered and accepted the
   credentials.
4. **Live → Start Streaming**. The session registers the system, registers a
   datastream per enabled sensor, then starts posting.
5. **Systems → Registration → This device's datastreams** lists what the node
   now holds, with live sent / bytes / error counts beside each one this session
   is feeding.

### Transport security

The app target sets `NSAppTransportSecurity` with **`NSAllowsArbitraryLoads`**
alone, in `osh-ios-Info.plist`. This is a deliberate choice, not an oversight:

- OSH nodes are frequently HTTP-only, on private networks no public CA will
  issue a certificate for.
- The app is a field tool whose server is typed in by the user. There is no
  fixed endpoint to declare an `NSExceptionDomains` entry for, which is why
  there is no exception list — a per-host exception is exactly what a
  user-configured server cannot be.

**`NSAllowsArbitraryLoads` must stay the only key in that dictionary.** Adding
`NSAllowsLocalNetworking`, or either `NSAllowsArbitraryLoadsIn…` key, makes
iOS 10+ *ignore* `NSAllowsArbitraryLoads` — the granular key wins, and every
destination outside its scope goes back to being blocked. Both keys were set
here at first and the result was `-1022` against a node at `100.82.29.90` while
curl to the same URL returned `200`: the LAN worked, nothing else did.

Dropping the narrow key loses nothing. Arbitrary loads disables ATS for all
destinations, local ones included; `NSAllowsLocalNetworking` exists for apps
that want the LAN exemption *without* disabling ATS globally, which is the
opposite of what a user-configured server needs.
`NSLocalNetworkUsageDescription` is a separate mechanism — the iOS 14+
local-network privacy prompt — and is unaffected.

Without any of this, only *private* address ranges reach the node. An address in
`100.64.0.0/10` — what Tailscale and other CGNAT setups hand out — is not a
private range as far as ATS is concerned, so a tailnet node on plain HTTP was
blocked before a packet left the device while a `192.168.x.x` node worked. That
asymmetry is what the setting removes.

For an `https://` node whose certificate does not chain to a trusted root,
enable **Trust server certificate (self-signed)** on that server in Settings.
It is per server, off by default, and accepts the certificate only when the
challenge comes from that server's own host — see `NodeSessionDelegate`, which
the two REST clients, the command client and the observations WebSocket all
share so that a trusted node is reachable by every one of them or none.

A node reachable from outside a trusted network should still use HTTPS with a
certificate that validates normally.

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
- **H.264 video is not decoded.** MJPEG streams render; an H.264 camera shows a
  placeholder card that reports its arriving frame rate and frame sizes, which
  proves the stream works without pretending to draw it. Pass 3d.
- **Only PTZ cameras can be commanded.** `PTZCapability` recognises pan/tilt/
  zoom control streams and drives them; every other control structure gets its
  parameter tree read-only and says "command support for this structure not yet
  implemented". Nothing guesses at a schema it does not recognise.
- **Command status is barely readable.** The reference node has no per-command
  resource and retains exactly one command per control stream, so
  `getCommandStatus` can only ever confirm the last command sent. It returns nil
  rather than pretending otherwise.
- **PTZ presets are a text field, not a menu.** The schema declares a `Text`
  with no `AllowedTokens`, so the app genuinely does not know what presets a
  camera has. An empty menu would be a worse lie than an empty field.
- **The video wall caps at four streams.** A fifth pauses the longest-playing
  one. The cap is a guess at what a phone tolerates and has not been measured on
  a device.
- **Clustering is the app's own, not MapKit's.** SwiftUI's `Map` exposes no
  clustering on iOS 18, so `MarkerClustering` does it: a greedy pass keyed to
  the camera's span. It is O(n²) in the markers held, which is nothing at the
  hundreds a map can hold and would need a grid or a quadtree at tens of
  thousands.
- **Re-grouping happens when a gesture ends, not during it.** Re-clustering
  every frame of a pinch would rebuild every annotation at 60 Hz for a grouping
  nobody can read mid-gesture. The pins settle when the fingers lift.
- **A far-flung system still spreads the map.** Grouping fixes markers hiding
  each other; it cannot fix a node whose systems are genuinely 13,000 km apart.
  The reference node's KrakenSDR is configured with a static location in central
  India while everything else is in Alabama, so the initial frame spans both and
  each site collapses to one bubble. That is correct, and it is also a hint that
  the map could use a "fit to what is nearby" affordance.
- **A chart card does not backfill from the archive.** Positions and scalar
  series bootstrap from the last half hour and bearings from their last
  observation, but a spectrum starts empty and fills as frames arrive, so a
  waterfall on a quiet stream reads "waiting for spectra".
- **Live Activity and camera preview are device-only.** Both are wired up but
  cannot be exercised meaningfully in the simulator.
- **Six tabs means a "More" tab.** iOS collapses tabs past the fifth on iPhone,
  so Logs and Settings live behind **More**.

---

## Roadmap

- **H.264 decoding** (Pass 3d), so the node's cameras render rather than
  reporting their frame rate.
- **More command structures.** PTZ is recognised and driven; the next ones are
  whatever the schemas on a real deployment turn out to describe. The read side,
  the envelope and the ordered-body discipline are done.
- **Commands *to* this device**, so a node can drive the phone rather than only
  listen to it — the app publishes no control stream of its own yet.
- **Configurable activity thresholds.** Five minutes is right for a camera and
  absurd for a tide gauge; `ActivityThresholds` is already the only place that
  would have to change.
- **MJPEG** *output* alongside H.264, for clients that cannot decode a bare
  Annex-B stream.
- **Garmin** wearable sensors as an additional set of outputs.
