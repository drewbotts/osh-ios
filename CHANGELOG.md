# Changelog

All notable changes to OSH iOS. Entries are grouped by development pass rather
than by release, because the app has not shipped a versioned build yet.

---

## Pass 3b — the viewer

Systems discovered on a node are now matched to visualisations **purely from
their data structures**. Nothing in the viewer asks which driver wrote a stream:
a map marker, a bearing dial, a waterfall or a video tile is chosen because the
record carries a location vector, an azimuth, a numeric array or a binary block.
That is what lets the app render a KrakenSDR it has never seen with the same
code that renders this phone, and why no stream on any node is unviewable — a
schema nothing else matches still renders as labelled rows.

Built and verified against a live node holding thirteen systems and forty-eight
datastreams. The test suite still runs from the committed fixtures alone.

### Added

**Datastream role inference** (`OSHiOS/Viewer/DatastreamRole.swift`). Eight
ordered rules turn a `DataRecord` and its binary encoding into a
`DatastreamRole`: `.location`, `.orientation`, `.bearing`, `.video`, `.chart`,
`.timeseries`, `.status` or `.generic`, each carrying the field paths its card
needs. Keywords longer than four characters match as substrings; shorter ones —
`doa`, `lob`, `aoa`, `id` — match whole tokens only, because `globe` contains
`lob` and half the fields in any schema contain `id`. The rules, the keyword
lists and how to extend both are documented in `OSHiOS/Viewer/ROLES.md`.

**Entity keys** (`EntityKey.swift`). One AIS datastream carries every vessel in
range, so "the latest observation" is not a position — it is whichever ship last
transmitted. The MMSI is found from the schema and observations are bucketed by
its value, giving one marker per vessel. Only location streams are grouped:
every stream has an identifier somewhere, and splitting a weather station's
readings by its own serial number produces one bucket and a lot of ceremony.

**Embedded positions.** `RemoteDatastream.embeddedPosition` resolves a location
vector at *any* depth in any record, so a system that publishes no position
output still lands on the map. KrakenSDR states where it stands inside its
settings record at `/stationConfig/location`, with the array heading beside it.

**`RemoteSystem` and `RemoteSystemLoader`.** A system resolved far enough to
draw: its datastreams with roles, its subsystems, its control-stream count and
its deployment location. Schemas are fetched four at a time and put back in
listing order; a datastream whose schema will not decode becomes a `.generic`
one carrying its error text, so one bad schema costs that card and not the
screen. Systems are cached per `(server, system)` for five minutes.

**`SystemLiveSession`.** One system watched live: an `ObservationStream` per
selected datastream, all of them routed through a single `TimeSynchronizer` so a
video frame and the fix taken at the same instant are published together.
History rings at 300 per datastream; video blocks go to the MJPEG decoder rather
than into a ring. Video is excluded from the default selection — bandwidth is
the scarce thing on a phone — and the whole set is capped at eight sockets,
ordered so a position or a line of bearing outranks a settings dump.

**Archive bootstrap.** Positions and scalar series pre-fill from the last half
hour; bearings and embedded positions fetch a single most-recent record of any
age, because a direction-finding output emits only on detection and its last LOB
may be months old and still the thing to show. Overlap with the live edge is
deduplicated by phenomenonTime to the millisecond, per datastream and entity.

**The system browser** (`Views/Browser/`). Every system on the node with its
glyph, ids and badges — datastreams, subsystems, control streams — loaded lazily
as rows appear, with a search field over names and UIDs. Replaces the read-only
"Browse systems on node" disclosure group on the Node tab.

**The system dashboard.** A grid of role-driven cards: a map card with rotated
markers per entity, a heading dial, a bearing compass with a prominent "as of"
line, an MJPEG player, a spectrum waterfall, rows with sparklines, a grouped
settings list. Cards are ordered status → bearing → the rest, so a
direction-finding station reads top-down as "here is the station, here is what
it heard". The session starts on appear and stops on disappear.

**Node mode on the Map tab.** A segmented control between "This Device" — the
existing track map, unchanged — and "Node", which plots every positioned system
on the node. Position source is `PositionKind`: `.live` from a location
datastream, `.reported` from an embedded position, `.deployed` from the system
resource, each with its own marker treatment. Up to five systems hold live
subscriptions, chosen by freshness; the rest show their last archived position.
Tapping a marker opens a sheet with the same cards in the same order.

**Lines of bearing.** Drawn from a system's position at the observed angle, with
the endpoint computed geodesically — never as a screen-space rotation, which at
60° north would turn a 45° bearing into a 63° line. A LOB fades to 30% after a
minute and is **never** removed, because direction finding emits only on
detection and "the last thing we heard" is the answer to the question being
asked.

**SDR waterfall** (`WaterfallBuffer.swift`, `WaterfallView.swift`). 200 rows of
amplitude as colour, newest at the top: one memmove and one row of pixels per
observation, a viridis colormap, a rolling dB range with 5% headroom, and a
`CGImage` rebuilt off the main actor. No per-pixel views and no Charts. A
frequency-axis chart defaults to it, with a Waterfall | Spectrum toggle.

**MJPEG decoding** (`Viewer/Video/MJPEGDecoder.swift`). JPEG blocks to
`CGImage` through ImageIO, on an actor so a 1280×720 frame never decodes on the
main actor. A truncated frame is dropped rather than half-drawn: ImageIO reports
an incomplete JPEG as complete and returns the top half of the picture, so the
SOI and EOI markers are checked first. H.264 blocks are counted and sized into a
placeholder card that proves the stream works — decoding them is Pass 3d.

**`listControlStreams`** on the read client, and `ControlStreamSummary`. Listed
read-only; commanding is Pass 4.

**`fetchMostRecent(datastream:limit:decoder:)`** on the read client. On the
reference node `phenomenonTime=latest` means *the current value of a live
stream*, so a datastream that has stopped publishing answers with an empty
collection however full its archive is. This takes that fast path for an open
stream and otherwise queries the tail of the datastream's own reported time
range, widening the window until records turn up. Without it every
direction-finding output on the node showed "no detections yet".

**A `kraken-doa` fixture** — the KrakenSDR DOA output, captured over REST
because the stream emits only on detection and the WebSocket capture times out,
exactly as the other archive-only fixtures were. `capture-fixtures.sh capture`
now takes an optional slug filter so one fixture can be refreshed without
rewriting the committed rest.

### Changed

**Credentials are optional.** A server may be saved with no username and no
password, and an empty username means **no `Authorization` header at all** —
in the read client, the write client and the WebSocket handshake alike. Sending
`Basic OjE=` is not neutral: a node with anonymous read enabled tries to
authenticate the empty user, fails, and answers 401 for a resource it would have
served happily to a request with no header. The Keychain stores an empty
password by removing the item rather than writing zero bytes.

**`LocationPaths.resolve` searches recursively**, breadth before depth, so a
top-level fix still wins and a position buried in a settings record now
resolves. Heading resolution follows it: `HeadingPath.resolve` looks among the
location vector's siblings first and only then at the record's top level,
because a heading belongs to the position it was measured with. It prefers a
true heading over a plain one over course over ground — one is where the hull
points, the other where the ship is going.

**`SensorCard` is a thin wrapper.** Its three bodies moved to
`Views/Shared/FieldRowsView`, `LocationSummaryView` and `VideoBadgeView`, which
the node dashboard now shares. The Live tab renders exactly what it did.

**`DatastreamDetailView` is reachable for remote datastreams**, from an info
button on every dashboard card — closing the drill-down gap Pass 3a left. It now
fetches its ten observations with `fetchMostRecent`, so an archive-only stream
shows records instead of nothing.

**The Map tab has two sources.** The device track map is unchanged and none of
the node code can reach it: a track being recorded has to keep working whether
or not a node is configured, reachable or interesting.

### Notes

`.deployed` positions are implemented and unit-tested but could not be verified
against the reference node — no system there carries a geometry in its
registration or its sampling features.

Two Tempest outputs (`Rain Start Event`, on both weather systems) classify as
`.generic`: their record is a bare timestamp with no numeric leaf at all, which
is exactly the case rule 8 exists for. They render as an empty row list with
their arrival time, which is all there is to show.

---

## Pass 3a — schema-driven SWE Common decoder

The app can now read a datastream it did not write. A schema fetched from any
OpenSensorHub node is decoded into a component tree, walked once into a parser
tree, and fed messages in either `application/swe+json` or
`application/swe+binary` — the same tree serving both formats, ported from the
parser architecture in osh-js. Nothing about the write path changed.

Everything here was built against a live node and its captured fixtures. The
test suite runs from the fixtures alone, with the node unreachable.

### Added

**A complete SWE Common vocabulary.** `SWECategory`, `SWEBoolean`, `SWETime`,
the four Range types, `SWEDataChoice`, `SWEMatrix`, `SWEGeometry` and `SWEHref`
join the existing components, along with `AllowedValues`, `AllowedTokens` and
`NilValue`. Existing types gained `description`, `id`, `optional`, `updatable`,
constraints and nil values as appended stored properties with defaults, so every
call site in the encoder still compiles unchanged.

**`SWESchemaDecoder`.** SWE JSON into a `DataComponent` tree, discriminating on
`"type"` with `JSONSerialization` rather than `Codable` — the containers are
heterogeneous and polymorphic. Records component ids into an index so an
`elementCount` `href` or a `#ref` can be resolved, and carries the path into
every error so a failure on a real node is diagnosable from the Logs tab.

**`SWEParserTree` and the token sources.** The schema is walked once; each
message is decoded by feeding the tree a `TokenSource`. `JSONTokenSource` reads
swe+json, om+json and single records by path; `BinaryTokenSource` reads
swe+binary positionally against the encoding's member table. A `DataArray` is
walked element by element unless the binary encoding puts a `Block` at the
array's own path, which is how a video frame is told from a spectrum.

**`DatastreamDecoder`, `ObservationStream`, `TimeSynchronizer`.** A datastream
facade pairing a schema with its tree; a reconnecting WebSocket subscription
that decodes on the way in; and a port of OSHConnect-Java's TimeSynchronizer
that buffers observations from several datastreams and releases them in
phenomenonTime order.

**`ConnectedSystemsReadClient` gained** `getDatastreamSchema`, `makeDecoder`,
`fetchObservations` with link-based paging, `listSubsystems` and
`getSystemLocation`.

**`scripts/capture-fixtures.sh`** surveys a node and captures the fixture tree,
including binary observations over a standard-library WebSocket client with a
REST fallback for archive-only datastreams. Seven fixture folders cover every
distinct schema shape the reference node serves.

**`OSHiOS/SWE/Decode/BINARY_FORMAT.md`** records each swe+binary layout, the
fixture it was verified against, and — for the DataChoice selector — that it
could not be verified at all.

### Fixed

**Media types in query strings lost their "+".** `URLComponents` leaves "+"
literal in a query value, so every `obsFormat=application/swe+json` request
reached the node as `application/swe json`. Schema fetches answered 400 and
observation fetches 302'd to an error page that itself 401s, so no failure named
the cause. This affected the existing read client, not only new code: with it
fixed, all forty datastreams on the reference node decode.

### Changed

**The Node tab shows a decoded schema tree** instead of a raw JSON dump, with
the raw document behind a toggle — when a node serves something unexpected, the
bytes are the only way to see what happened. A "Last 10 observations" section
renders each observation's leaves as path → value.

**`fetchObservations` takes `latest:`.** The node orders observations ascending,
so a plain `limit: 10` returns the ten oldest records in the archive.

**`buildBinaryObsBody` is internal rather than private**, so the round-trip
tests can prove the decoder is its exact inverse. Behaviour is unchanged.

### Notes on the node

Where this pass's spec and the node disagreed, the node won:

- swe+json observations arrive as a bare JSON array, not `{"items": […]}`.
- A `DataArray`'s binary member is keyed by the element *type's* name, once,
  rather than once per index.
- UTF-8 text is spelled `string-utf-8` and is framed as a 2-byte big-endian
  length then modified UTF-8.
- A video datastream has no swe+json schema at all; the node answers 400.
- om+json omits the record's Time field from `result` for some drivers and
  leaves the instant to the envelope — and on a replayed datastream the two
  differ by the age of the archive.

---

## Pass 2 — UI restructure and viewer foundations

The app grew from a single form into six tabs, and the pieces a future data
viewer needs were put in place. Nothing about what the app sends to an OSH node
changed: the SWE field names, definition URIs, ordered-string JSON builders and
observation encodings are byte-for-byte what Pass 1 produced.

### Added

**A typed observation model.** `FieldPath`, `FieldValue` and `ParsedObservation`
replace the untyped `[Double]` the UI used to read. `SchemaWalker` maps a
sensor's flat value array onto its schema's ordered leaf paths, giving every
value a path and a type — a time as a `Date`, a count as an `Int`, a video frame
as a tagged binary block. Nothing in the model refers to a local sensor, so an
observation fetched from a node will flow through the same types.

**A read client.** `ConnectedSystemsReadClient` lists and fetches systems,
datastreams and raw schema documents. Its `SystemSummary` and
`DatastreamSummary` decode tolerantly: GeoJSON or SensorML-JSON shapes,
`"system@id"` or `"system@link"`, string or numeric ids, and any unfamiliar key
without failing the collection.

**`NodeConnection` and `NodeConnectionStore`.** One object per configured node,
owning both the read and write clients, injected as an environment object and
rebuilt whenever the selected server's URL, credentials or identity change.
Before this, each feature built its own client against the same host.

**Live sensor state.** `SensorLiveState` carries an output's schema, its latest
and last-60 parsed observations, staleness, and per-datastream delivery
counters. `ObservationPublisher`'s status stream now reports sent, byte and
error counts per datastream; video reports its own from the direct-post path.

**Encoder telemetry.** `VideoOutput` publishes encoded FPS, bitrate, dropped
frames and real encoded dimensions once per second over an `AsyncStream`, and
exposes its `AVCaptureSession` so the Camera tab can attach a preview layer.

**Session track.** GPS fixes accumulate into `[TrackPoint]`, capped at 5,000
points and decimated rather than truncated past that, so a long run keeps its
whole shape. GPS horizontal accuracy travels beside the observations on its own
channel, since the SWE record deliberately does not carry it.

**In-app log store.** `LogStore` is a 2,000-entry ring that `Log.*` writes to
alongside `os.Logger`. Call sites are unchanged — `OSHLogger` accepts the same
interpolation, privacy annotations included, and renders the redaction itself so
the Logs tab shows exactly what Console.app would. `OSLogStore` is not used; it
is unreliable in-process.

**Six tabs.**

- **Live** — session bar (state, elapsed time, buffering count, one primary
  button) over a grid of sensor cards.
- **Camera** — live preview with an encoder overlay, and codec, resolution,
  frame-rate and bitrate controls, locked while a session runs.
- **Map** — MapKit track, accuracy circle and current fix, with Follow and Clear.
- **Node** — server picker, connectivity test, cached registration and its
  reset, the node's datastreams with live counters, a raw schema viewer, and a
  read-only system browser.
- **Logs** — filtered, auto-scrolling log tail with copy and clear.
- **Settings** — system name, servers, sensor enables, sample rates,
  auto-start, and version info.

**A schema-driven sensor card.** `SensorCard` picks its body from
`SensorCardKind.from(schema:)` — a Location vector, a binary DataArray, or
labelled rows with Swift Charts sparklines — and reads labels and units from the
components. It contains no reference to any sensor class, because the viewer
will point it at datastreams that have none.

**Live Activity.** A new `OSHiOSWidgets` extension renders the streaming session
on the Lock Screen and in the Dynamic Island. Updates are pushed on connectivity
changes and at most every 30 s; elapsed time is a system-ticked timer rather
than a pushed value, to stay inside ActivityKit's update budget.

**Background location.** The app declares the `location` background mode and
enables background updates when authorization allows, so GPS keeps producing
while the screen is locked. Always authorization is never requested.

**Configurable sample rates.** Orientation (0.05–1.0 s) and audio level
(0.1–1.0 s) intervals are settable, and flow through to the modules'
`averageSamplingPeriod` so the node is told the rate it will actually receive.

**Auto-start on launch**, off by default.

**A 1080p video preset** beside the existing 720p one, each keeping its own
bitrate.

### Changed

- SWE model types moved from `OGC/SWE/SWEHelper.swift` into `SWE/Model/`, one
  concern per file. The schema *builders* stayed where they were.
- `SensorSession.start` takes a `NodeConnection` instead of a `ServerConfig`,
  and uses its write client rather than constructing one. Per-server cached-id
  scoping is unchanged.
- `SensorSession.sensorStatus: [String: String]` — a dictionary of formatted
  strings — became `sensors: [String: SensorLiveState]`.
- `AppConfig` and `VideoConfig` decode every key optionally, so a config written
  by an earlier build loads instead of silently resetting to defaults.
- Sensor configuration moved from view-local `@State` into `AppSettingsStore`,
  so Settings and the tabs that read it cannot drift apart.
- `postObservation` returns the number of body bytes sent, for throughput stats.
  What it sends is unchanged.
- `NoRedirectDelegate` became internal and moved to its own file, shared by both
  clients.
- `SensorSession` is created once in `osh_iosApp` and injected, rather than
  being owned by a view.

### Fixed

- **Scalar observations never reached the node.** Pass 1 posted a flush's worth
  of records as one JSON array; the OSH node's swe+json binding reads exactly
  one record per request and rejected every one of them with
  `Expected BEGIN_OBJECT but was BEGIN_ARRAY`. The node forwards that 400 to
  `/sensorhub/error/invalid`, which its admin module denies and redirects, so
  the client only ever saw `HTTP 302` — with no body and no explanation. GPS,
  orientation, barometer and audio silently produced nothing for the whole of
  Pass 1; video was unaffected because it posts one frame per request.
  Observations are now posted one per request, as they were before Pass 1.
- **A rejected payload retried forever.** Any failed POST marked the publisher
  disconnected, requeued the records at the front of the ring buffer, and
  started a reconnect probe — which succeeded, drained, failed again, and
  looped. A 4xx or a redirect is now treated as a rejection: the observation is
  dropped and counted, the publisher stays connected, and the queue keeps
  moving.
- **Datastream time ranges never displayed.** `DatastreamSummary` decoded
  `phenomenonTimeRange` / `resultTimeRange`; the node sends `phenomenonTime` /
  `resultTime`, so both were permanently nil and the Datastream detail view's
  Time section was always empty. Both spellings are now accepted.
- **Failed requests logged nothing useful.** `ConnectedSystemsClient` now logs
  the path, status, what was sent, the `Location` header, and the response body
  on any non-2xx; `ObservationPublisher` includes the datastream id.

### Removed

- `ContentView`'s form layout, and the string-formatting status code that fed it.
- `ConnectedSystemsClient.postObservations` — the JSON-array batch POST. There
  is no server-side counterpart to fix it against.

---

## Pass 1 — Batching, video split, strict concurrency

### Added

- Per-datastream batching: scalar observations flush every 250 ms or at 50
  records, cutting one HTTP round-trip per sample to one per flush. *(The array
  payload this used was rejected by the node — see Pass 2's Fixed section. No
  scalar observation shipped in Pass 1 ever reached a server.)*
- A 1,000-entry ring buffer and exponential-backoff reconnect probe (1 s → 30 s)
  so a node going down buffers instead of losing data.
- A publisher status stream carrying connectivity, queue depth and totals.
- Per-server scoping for cached system and datastream ids.
- Unified logging via `Log.*`, replacing `print`.
- Unit tests for the ordered-JSON invariant, fractional-second timestamps,
  heading normalisation and ring-buffer behaviour.

### Changed

- Video was split out of `ObservationPublisher` entirely. Frames post directly,
  one at a time, behind an in-flight gate that drops rather than queues — a
  frame-sized payload in the scalar ring buffer would evict real sensor data.
- Datastream schemas are built from the capture device's *active format* rather
  than from the configured preset, so registration advertises the size the
  encoder will actually produce.
- Euler orientation reports full heading, pitch and roll referenced to true
  north (`xTrueNorthZVertical`).
- `SWIFT_STRICT_CONCURRENCY = complete` across the project.
- The session state machine gained a defer-based safety net: every exit from
  `.connecting` reaches `.streaming` or `.failed`, so the UI can never stick.
