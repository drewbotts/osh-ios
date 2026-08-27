# Changelog

All notable changes to OSH iOS. Entries are grouped by development pass rather
than by release, because the app has not shipped a versioned build yet.

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
