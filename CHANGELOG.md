# Changelog

All notable changes to OSH iOS. Entries are grouped by development pass rather
than by release, because the app has not shipped a versioned build yet.

---

## Pass 3e — reaching a remote node (0.9.1)

A node on a remote address could not be connected to at all while a node on the
same LAN worked. Two separate causes, stacked:

**App Transport Security was never configured.** With no `NSAppTransportSecurity`
key, only private address ranges reached a plain-HTTP node. `100.64.0.0/10` —
what Tailscale and other CGNAT setups hand out — is not a private range as far
as ATS is concerned, so `http://100.x.y.z:8080` was refused before a packet left
the device while `http://192.168.x.x:8080` was allowed. The README had claimed
ATS "allows arbitrary loads for local addresses", which was not true of a build
that set nothing.

**The HTTPS alternative could not be trusted.** The same node offered TLS on
another port, but with a self-signed certificate (`CN=ogc-demo`, issuer equal to
subject, and a SAN naming only `DNS:ogc-demo` — no IP). iOS rejected it with
`-1202`, and the app had no way to say otherwise. Both routes to the node were
therefore closed, and the app reported only "Connection failed".

### Added

**`NSAppTransportSecurity` on the app target**, `NSAllowsArbitraryLoads` and
nothing else, in `osh-ios-Info.plist` — the widget's plist is untouched.
Deliberately not an `NSExceptionDomains` list: a per-host exception is exactly
what a server the user types in cannot be.

That key has to stand alone. `NSAllowsLocalNetworking` was set beside it at
first, on the assumption that the two are evaluated independently; they are not
— iOS 10+ **ignores `NSAllowsArbitraryLoads` whenever a granular key is
present**, so the app still refused plain HTTP to `100.82.29.90` with `-1022`
while curl to the same URL returned `200`. Removing the narrow key loses
nothing: arbitrary loads disables ATS for local destinations too, and
`NSLocalNetworkUsageDescription` — the iOS 14+ privacy prompt — is a separate
mechanism and unaffected.

**`ServerConfig.allowSelfSignedCertificates`**, per server and off by default,
with a **"Trust server certificate (self-signed)"** toggle in `ServerDetailView`
and a footer saying what it does. Persisted through `KeychainServerStore`, whose
stored `Metadata` takes the flag as an *optional* Bool: a record written before
the field existed has no such key, and a non-optional would have failed the
whole decode — losing every configured server rather than one setting.

**`ConnectionErrorMessage`**, one mapping from a transport failure to words that
name the fix. `-1022` names HTTP, the certificate family (`-1200`, `-1202`,
`-1203`, `-1201`, `-1204`) points at the trust toggle, and timeout, unreachable
and offline each get their own line. Anything unmapped defers to the system
description rather than inventing one. `SensorSession.userFacingMessage(for:)`
and `testConnectivity()` both read from it, so the Systems tab status row, the
session banner and the log stop phrasing one failure three ways.

### Changed

**`NoRedirectDelegate` is now `NodeSessionDelegate`**, carrying certificate
trust as well as redirect suppression — the old name would have described half
of what it does. A self-signed certificate is accepted only when the flag is on
*and* the challenge host equals the configured server's host; every other path,
including a non-certificate challenge, falls through to default handling. It is
now shared by all four callers: both REST clients, the command client and — new
— the observations WebSocket, which built a bare `URLSession(configuration:)`
with no delegate and would have refused to stream from a node the user had just
trusted for everything else.

**A redirect is no longer reported as a successful connection.**
`testConnectivity()` treated any non-401 status as `.connected`, so a 3xx read
as "Connected" while every subsequent listing failed. It now returns
`.unreachable("Server redirected to <Location> — update the server URL")`,
naming the header that makes it actionable.

**`NodeConnectionStore` rebuilds on a trust change.** Its `differs` check
compares the fields the clients are constructed from, and
`allowSelfSignedCertificates` was missing from it — so turning the toggle on
for a server that was already selected kept the existing connection, whose
delegates had been built for the old value, and the setting appeared to do
nothing at all. Every field the clients read is now in that comparison, with a
test per field.

**Every deployment target is 26.0.** The app target had been raised while
`osh-iosTests`, `osh-iosUITests` and `OSHiOSWidgets` stayed at 18.5, so the test
target could not compile against the app module — the suite did not build at
all.

### Fixed

Five pre-existing strict-concurrency warnings, all of which a clean build
surfaced and an incremental one had been hiding. Three shared
`ISO8601DateFormatter` statics gained the `nonisolated(unsafe)` that
`ObservationStream`'s equivalent already carried. The two Live Activity handles
move through an `ActivityHandle` box: `Activity`'s `update` and `end` are
nonisolated `async`, so awaiting either from a `@MainActor` type sends a
non-Sendable value off the actor whatever the enclosing task is isolated to.

### Tests

`NodeSessionDelegateTests` covers the delegate's decisions — flag off, flag on
against a different host, flag on with no configured host, a host that only
shares a suffix, a Basic-auth challenge under both flag settings, and redirect
suppression. `ConnectionErrorMessageTests` covers the mapping and asserts the
session banner agrees with it. `ServerConfigTrustPersistenceTests` decodes both
a legacy record and a current one, and checks host derivation from a URL with a
scheme, port and path.

`NodeConnectionStoreTests` asserts a rebuild for each of url, username,
password and trust, and no rebuild when nothing changed — identity being the
observable difference, since the clients capture their policy at init.

`LiveNodeTests` gained a connectivity test and reads
`OSH_TRUST_SELF_SIGNED`, so the live suite can be pointed at a self-signed
`https://` node. Verified against a real node over both a LAN address and a
tailnet one: HTTP 6/6, HTTPS with the flag on 6/6 including the WebSocket
subscribe, and HTTPS with the flag off failing 6/6 with `-1202` and
"Certificate not trusted" — the negative control that shows the default is
unchanged. The tailnet HTTP run is the one that would have caught the ATS key
conflict, and did.

---

## Pass 3d — TestFlight distribution

No behaviour change: build configuration, distribution metadata and one release
document. `xcodebuild archive -destination 'generic/platform=iOS'` now completes
signed, with zero compiler warnings, and the app and its widget carry matching
versions.

### Added

**`PrivacyInfo.xcprivacy`**, one file listed in the Resources phase of both the
app and the widget extension — each bundle is validated separately and an
extension without a manifest is rejected on upload. Two required-reason APIs are
actually reached and both are declared: `UserDefaults` (`CA92.1`, the app's own
settings) and `systemUptime` (`35F9.1`, `VideoOutput` turning a frame's
uptime-based presentation timestamp into a wall-clock instant). File timestamps,
disk space and active keyboards were checked for and are not used. No tracking,
no collected data types.

**`scripts/stamp-build-version.sh`**, a last build phase on both targets. It
rewrites the *built* `Info.plist` — `CURRENT_PROJECT_VERSION` is consumed while
that plist is generated, long before a script phase could change it — setting
`CFBundleVersion` from `git rev-list --count HEAD`, falling back to 1 without
git. Both targets run the same script over the same repository, so the app and
the extension get identical values by construction; App Store Connect rejects an
upload whose extension version does not match its app's. Every write is read
back and the build fails if it did not take: PlistBuddy exits 0 on some write
failures, and a version stamp that silently did nothing is worse than none.

**`docs/RELEASING.md`** — archive and upload steps, the version-bump policy, the
90-day TestFlight expiry and what it means for cadence, "What to Test" copy for
App Store Connect, and the portal-side work that cannot be done from here.

`NSLocalNetworkUsageDescription` and `ITSAppUsesNonExemptEncryption` in
`osh-ios-Info.plist`. Both belong in the file rather than in an `INFOPLIST_KEY_`
build setting: nodes are reached by IP on a LAN, so the first connection fails
silently without the former, and the latter has to be a real boolean, which a
build setting cannot produce.

### Changed

The bundle identifier is `org.opensensorhub.oshios`, from
`org.opensensorhub.osh-ios`, with the widget extension following it to
`org.opensensorhub.oshios.OSHiOSWidgets` — an extension's id has to stay a
prefix-child of its app's. The test bundles moved to `org.opensensorhub.oshios.tests`
and `.uitests` for consistency; they never ship. `Logging.subsystem` has said
`org.opensensorhub.oshios` since it was written, so the OSLog subsystem and the
bundle id finally agree.

Nothing in code reads the identifier, and the Keychain service is the hardcoded
`osh.ios`, so no source change was needed. But the identifier *is* the
UserDefaults domain and the default Keychain access group, so a device carrying
an older build sees the renamed app as a fresh install: saved servers, sensor
toggles and map layers are not migrated. Nothing has shipped, so the cost is
one re-entry on dev devices.

`MARKETING_VERSION` is `0.9.0` on every target. The four usage-description
strings were rewritten for a reviewer rather than a developer: the location one
now says recording continues while the screen is locked, and the microphone one
says only a loudness figure is sent and no audio is recorded.
`NSMotionUsageDescription` stays — `BarometerOutput` uses `CMAltimeter`, which
requires it.

The three 1024×1024 app icons are re-encoded without an alpha channel. They were
fully opaque RGBA, and an alpha channel — even an opaque one — is rejected as
ITMS-90717. Identical pixels, and a sixth of the bytes.

`ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app and widget targets, which is
what the stamping script needs to read `.git` and write the built plist. It
stays `YES` at the project level, so the test targets keep it.

`EXCLUDED_SOURCE_FILE_NAMES = "*.md"` on those same two targets. The
synchronized folder groups were sweeping `ROLES.md`, `COMMANDS.md` and
`BINARY_FORMAT.md` into the shipped bundle — 40 KB of internal design notes
inside the app.

---

## Pass 3c.1 — laser range finder targets

A laser range finder observation names a point *somewhere else*. Every rule in
the viewer up to now assumed a location vector in a record described the system
that published it, so the reference node's TruPulse output drew the range finder
itself sitting on top of whatever it was ranging to, and nothing joined the two.

### Added

**The `.target` role** (`OSHiOS/Viewer/DatastreamRole.swift`). Checked between
video and location, so it decides a record before the location rule can claim
it. It fires when a location vector resolves and either the vector is named or
defined as a target, or a Quantity *beside* it is a range, a distance or a slant
range. `TargetPaths` carries the target's coordinates plus the range, azimuth,
elevation and source-identifier paths when the record has them — the reference
node's `targetLoc` stream has none of them, publishing the numbers on a sibling
datastream instead, so all four are optional by design.

The rule order is now video → target → location → orientation → bearing → chart
→ status → timeseries → generic. A record with an azimuth and **no** location
vector is still a `.bearing`, asserted against both the Kraken DOA fixture and a
synthetic azimuth-plus-range record: the new rule adds a way for a location
vector not to be a position and takes nothing away from direction finding.

Range keywords are matched as whole tokens rather than as substrings, whatever
their length, via a new `firstLeaf(in:matchingAnyToken:)`. "range" is five
characters and a substring match finds it inside `AntennaArrangement`, which
would have reclassified KrakenSDR's settings dump as a laser range finder.

**`TargetSourceResolver`** (`OSHiOS/Viewer/TargetSourceResolver.swift`). A pure
function from an observation, its owner system and the loaded system list to the
system the target was observed *from*, which is where the line starts. Four
rules: an identifier stated in the record (matched against every system's id,
uid — including as a suffix, since a driver writes the tail it knows — and name,
with this device as a candidate); a `parent@id` link; the owner itself when it
has a position; and, only when none of those placed anything, a shared
eight-character-or-longer token between two systems' UIDs, ranked by how many
colon-separated segments the two share and on a tie by which candidate's UID
says the least beyond them.

That last rule is the one the reference node needs and the one no node states.
Its range finder registers as `urn:lasertech:trupulse360:7ae57419dd427e4c:replay`
and the phone carrying it as `urn:osh:android:7ae57419dd427e4c:droid2:replay`:
no parent link, no subsystem entry, no identifier in the record, and a
sixteen-character device id in common. It is consulted last, only for an owner
with no position of its own, and ranks candidates on `hasPosition` rather than
on the caller's position lookup, so which system wins stays a pure function of
the list.

**Target rendering** (`COPMapAnnotations.swift`, `SystemMapView.swift`). A red
`plus.viewfinder` marker at the target, never rotated, labelled "412 m @ 087°"
when the record carries range and azimuth, with an `ActivityDot` from the
stream's freshness; and a straight red 2 pt `MapPolyline` from the source's
*current* position, so the origin follows the source when it moves. Both ends
are known, so unlike a line of bearing it needs no spherical projection. The
line fades after 60 seconds and is never removed, on `BearingStyle`'s own clock,
because a designation is an event like a detection is.

Only the latest target per (datastream, entity) is drawn. A "Target history"
layer — off by default — adds the last 20 designations as small dots with no
lines.

**The `.target` card** (`DatastreamCard.swift`). `TargetSummaryView`: range,
azimuth, elevation, the target's coordinates, the source system's name and a
prominent "as of". Tapping the source name sends the user to the map with that
marker selected, through a new `TabRouter.showOnMap(markerId:)`. The systems
needed to name a source are lent to the card by the host — `TargetCardContext`,
passed by the COP map's marker sheet and by the systems list through
`SystemDashboardView(peers:)` — rather than loaded a second time.

**Fixtures `lrf-target` and `lrf-range`.** The reference node's TruPulse 360
outputs, with `system.json` and `subsystems.json` for the range finder *and* for
the Android phone it is carried by. The empty subsystem collections are captured
rather than omitted, because "the range finder is not a subsystem of the phone"
is the fact the resolver's fourth rule exists for.

### Changed

`RemoteDatastream.embeddedPosition` is nil for a `.target` stream, as it already
was for `.location` — the coordinates are not this system's, and treating them
as one is exactly the bug being fixed. `EntityKeyInference` now groups `.target`
streams too, excluding the source-identifier field from the candidates: it names
who was looking, not what was looked at. `SystemLiveSession` bootstraps a
`.target` stream with `limit: 1` of any age, the plan a `.bearing` stream gets.
`COPMapModel` keeps a target-carrying system live and fetches its archived
target even when the system has no position of its own, and its three copies of
"does this datastream draw on the map" are now one `drawsOnMap` predicate.

The Kraken line of bearing is unchanged in every respect, and
`DatastreamRoleTests.targetRuleChangesNothingElse` asserts the role of every
other captured fixture.

### Fixed

`LiveNodeViewerTests.directionFindingStationRenders` required every system with
a bearing output to have a position, which only held because the range finder's
target was being read as its own position. It now asserts the honest
consequence: nothing locates such a system, so it gets no marker and no line —
a bearing line needs an origin.

`NodeBrowseUITests` guarded on `OSH_NODE` with `XCTUnwrap`, which *fails* rather
than skips, so the UI test target reported a broken test on every run of the
default fixture-only suite. It throws `XCTSkip` now, as its own header always
said it did.

Two suites in `MarkerClusteringTests` are `@MainActor`, which is where the types
they exercise live: `DeviceLayer` is isolated outright and `SystemMapView`'s
statics inherit it from `View`. Twenty-one Swift 6 concurrency warnings, gone.

---

## Pass 3c — the common operating picture

The viewer stops being a set of per-system pages. Three tabs now answer one
question each about the *whole* node — where is everything, what can everything
see, what is everything — and a camera that accepts commands can be driven from
inside the app.

Built and verified against a live node holding thirteen systems, six control
streams and two Axis PTZ cameras. The default test suite still runs from the
committed fixtures alone and touches no network.

### Added

**System activity** (`OSHiOS/Viewer/SystemActivity.swift`,
`ActivityTracker.swift`). One freshness picture, shared by every surface:
`.live` at five minutes, `.stale` at thirty, `.offline` beyond. Derived in three
layers — a `DatastreamSummary`'s reported time range classifies a whole node
without opening a stream, arriving observations promote a system in real time,
and this device is live by definition while its session streams. A range ending
in `now` or `latest` means data is flowing and counts as live, which is what
makes a replay-backed node read as live rather than as an archive. A 30-second
timer re-evaluates everything, because a system that goes quiet produces nothing
to notice it with. Thresholds live in `ActivityThresholds` and nowhere else.

**`ActivityDot`** (`osh-ios/Views/Shared/ActivityDot.swift`). Green, amber, red,
with an accessibility label and an optional "12 min ago". Drawn on map markers,
systems-list rows, dashboard card headers and video-wall tiles — one view rather
than four coloured circles, so they cannot disagree.

**The common operating picture** (`osh-ios/Views/Map/COPMapView.swift`,
`COPMapModel.swift`, `COPMapAnnotations.swift`, `DeviceLayer.swift`). One map.
This device's track, fix and accuracy circle are drawn beside every positioned
system on the node, with bearing lines and multi-entity markers. Layers — this
device, node systems, tracks, bearing lines, labels — and the live-updates
switch live in a toolbar menu and persist in `AppConfig.mapLayers`. Tapping this
device's marker follows it; tapping a system's opens its cards and a link to its
dashboard.

**The video wall** (`osh-ios/Views/Video/`). Every video datastream on the node
in a grid — two up in portrait, three across in landscape — with this device's
camera preview as the first tile. At most four MJPEG streams play at once and
the fifth pauses the longest-playing one, round-robin, because the user tapping
a fifth tile wants that tile. Autoplay defaults to WiFi-only, decided by
`NetworkPathObserver` over `NWPathMonitor`. Tapping a tile opens a full-screen
player.

**PTZ control** (`OSHiOS/Viewer/Control/PTZCapability.swift`,
`osh-ios/Views/Shared/PTZControlView.swift`). A control stream whose parameters
are a `DataChoice` carrying a relative or absolute pan/tilt pair is recognised
as a camera and given a D-pad, a zoom pair, a preset field and an absolute
panel — overlaid on the full-screen player and available on the dashboard. The
pad auto-repeats while held, and never has more than one command in flight: a
camera sent a move every 200 ms builds a queue it works through long after the
finger comes off. Detection reads definitions before names, exactly as
`DatastreamRole` does; the rules are in `ROLES.md`.

**`CommandClient` and `CommandBody`** (`OSHiOS/Client/`). `POST
/controlstreams/{id}/commands` with bodies built as ordered strings, never by
`JSONEncoder` — the node reads a record's fields in schema order and answers 400
for anything else. The verified envelope, every captured request and response,
and the endpoints that turn out not to exist are documented in
`OSHiOS/Client/COMMANDS.md`.

**Control streams resolved, not counted.** `RemoteSystem.controlStreams` now
carries each stream's decoded parameters schema and its `PTZCapability`;
`controlStreamCount` became a computed property so every existing call site goes
on meaning what it meant.

**Marker grouping** (`osh-ios/Views/Map/MarkerClustering.swift`,
`osh-ios/Views/Shared/ClusterMarkerView.swift`). Markers closer together than a
touch target are drawn as one bubble with a count, and the grouping dissolves as
the camera zooms in — the cell size is derived from the map's span and its size
in points, so nothing in the app has a notion of "zoom level". Tapping a bubble
zooms to fit its members; a group whose members share one coordinate exactly,
which no zoom can separate, opens a list instead. This device is never grouped.

The grouping is greedy rather than a grid, because a grid has an artifact the
user sees at once: two markers a hair apart either side of a cell boundary stay
separate, so pins merge and split while panning. It also replaces most of what
decimation was doing — the cap rises from 100 markers to 400 when grouping is
on, because grouping breaks the link between markers held and annotations drawn.

**`MarkerView`** (`osh-ios/Views/Shared/`). Replaces `HeadingMarker`. A
role-tinted disc with the system's glyph, an `ActivityDot` fused to its top
right, and an arrowhead travelling round a ring *outside* the disc — so the
glyph stays upright. The old marker rotated the whole disc, which drew a camera
pointing south-west upside down.

### Changed

**Tabs.** Live, Video, Map, Systems, Logs, Settings. The Camera tab is the video
wall's first tile and pushes to `DeviceCameraView` for its encoder settings; the
Node tab is the Systems tab's header. Both were a single system's view of a
question the whole node should answer.

**Systems tab** (`SystemsTabView`). The old Node tab and the old system browser,
merged: server picker, connectivity, registration and publisher counters above,
every system below — sorted live-first then alphabetically, filterable by All /
Live only / With position / With video / With controls, with this device as the
first row. Systems load eagerly rather than per-row, because sorting by
freshness and filtering by "has video" both need the detail before the row is
drawn.

**`SystemDashboardView`** keeps its role as the per-system drill-down and stops
being the primary way to see anything. Control-stream cards come first on it: a
camera you can move is what you opened the screen for.

**Dashboard card headers** show data freshness rather than socket state. The
socket is still reported, in words, and only when it is worth saying — a stream
that is happily streaming is worth nothing at all.

**Map framing ignores Null Island.** Exactly `(0, 0)` no longer gets a vote on
where the camera opens when any real coordinate exists. The reference node's
second Axis camera registers itself there, and including it stretched the frame
from Alabama to the Gulf of Guinea. The marker is still drawn.

**`SystemGlyph`** gained the tint table that lived in the map's annotation code,
so a camera is the same colour on the map, in the list and on the wall.
`RemoteSystemLoader.loadAll` gained the load-a-whole-node task group that all
three surfaces had grown their own copy of. `SWESchemaDecoder` accepts
`parametersSchema` alongside `paramsSchema` and `recordSchema` — the same
document under two different `commandFormat` values.

### Removed

`NodeTabView`, `NodeMapView`, `NodeMapModel`, `HeadingMarker` and
`TrackMapView`. The first four were renamed or absorbed; `TrackMapView` was the
device-only map, and its accuracy circle and follow camera moved into
`SystemMapView` so the COP could draw both halves at once.

### Verified against the live node

The command envelope was determined empirically — the node serves no OpenAPI
document any of `/api/openapi`, `/api/api-docs` or `/api/openapi.json` will
return. Authorised small moves only, ending where they started:

```
Start position: 130.0
POST {"parameters":{"rpan":3.0}}   → 200 COMPLETED
Position after +3°: 133.0
POST {"parameters":{"rpan":-3.0}}  → 200 COMPLETED
Position after return: 130.0
```

Three node behaviours worth knowing, all captured in `COMMANDS.md`: an OSH node
serves its HTML admin console — and demands a login — for API paths requested
without an explicit `Accept` header, so a 401 is often a missing header rather
than a missing password; there is no per-command resource, and the control
stream retains exactly one command, so a status lookup can only ever confirm the
last command sent; and a partial or reordered record body is a 400 naming the
field the parser wanted next.

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
