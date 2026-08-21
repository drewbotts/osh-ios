# Changelog

All notable changes to OSH iOS. Entries are grouped by development pass rather
than by release, because the app has not shipped a versioned build yet.

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
