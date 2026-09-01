# Datastream role inference

How the viewer decides what a datastream *is*, and therefore how to draw it.

Nothing in the viewer matches on a driver, an output name or a system type. A
KrakenSDR the app has never seen gets a bearing dial for the same reason an
Android phone gets a rotated map marker: their schemas say so. That is what
makes the app work against a node nobody anticipated, and it is why every rule
below is written against SWE Common structure rather than against a vocabulary.

Implementation: `DatastreamRole.swift`, `EntityKey.swift`, `LocationPaths.swift`.

---

## The rules

Applied in order, first match wins. Every comparison is case-insensitive, and a
component's `definition` is checked before its `name` — the definition is the
interoperable part, the name is what a driver author happened to type.

| # | Role | Fires when | Carries |
|---|---|---|---|
| 1 | `.video` | the binary encoding has a `Block` member | the compression code |
| 2 | `.target` | a Location vector resolves, the record is not settings-flavoured, and **either** the vector is named/defined as a target **or** a Quantity beside it is a range/distance/slant range | `TargetPaths`: the target's `LocationPaths` + optional range, azimuth, elevation and source-identifier paths |
| 3 | `.location` | a Location vector resolves, and the record is neither settings-flavoured (rule 7) nor bearing-flavoured (rule 5) | `LocationPaths` + an optional heading path |
| 4 | `.orientation` | a Vector or record defined as Orientation/Quaternion, or a heading+pitch+roll triple | `OrientationPaths` (quaternion or Euler) |
| 5 | `.bearing` | a Quantity leaf matching a direction-finding keyword | the angle path + an optional quality path |
| 6 | `.chart` | a numeric DataArray that is variable-size or ≥8 elements | the series paths + an optional x-axis |
| 7 | `.status` | settings-flavoured: a name or definition containing settings/config/status, or ≥3 nested records with ≤1 top-level Quantity | — |
| 8 | `.timeseries` | at least one Quantity or Count alongside a Time | — |
| 9 | `.generic` | nothing else matched | — |

`.generic` is not a failure. It renders as labelled rows of whatever decoded,
which is why no stream on any node is ever unviewable.

### Rule 2: whose position is it

A location vector in a record does not automatically mean "this system is
here". A laser range finder publishes a lat/lon that belongs to whatever it was
pointing at, and a viewer that read it as a position pins the range finder on
top of its own target and draws no line between them. Rule 2 runs before rule 3
so that record is classified by *what the position is about*.

Two ways to qualify, and neither is a driver name:

* the location vector is itself named or defined as a target — `targetLoc`,
  "Target Location";
* a Quantity **beside** the vector is a range, a distance or a slant range,
  which is what a range finder measures and what a position record never
  carries.

The sibling restriction on the second test matters. A range three records away
describes something else, and a rule that scanned the whole tree would pull in
any settings dump that happened to state a position and a distance in unrelated
sub-records. These keywords are also matched as **whole tokens** rather than as
substrings, whatever their length: "range" is five characters and a substring
match finds it inside `AntennaArrangement`, which is how a KrakenSDR settings
record would otherwise be classified as a laser range finder.

A record with an azimuth and **no** location vector is still a `.bearing`. The
new rule adds a way for a location vector to *not* be a position; it takes
nothing away from direction finding, and `DatastreamRoleTests` asserts that on
both the Kraken DOA fixture and a synthetic azimuth-plus-range record.

`RemoteDatastream.embeddedPosition` is nil for a `.target` stream, for the same
reason it is nil for a `.location` one and a stronger one besides: the
coordinates are not this system's.

### Two exclusions on rule 3

The ordering above says location is decided before bearing, and rule 3 carries
two exclusions that would otherwise make that ordering wrong.

A **settings record with a position in it** stays `.status`. KrakenSDR's
settings output states where the station stands; the stream is still
configuration, and calling it a location would put a settings dump behind a map
card. The position is not lost — see *Embedded positions* below.

A **direction-finding record with a position in it** stays `.bearing`. Every LOB
KrakenSDR emits is stamped with the station's own coordinates. The subject of
the stream is the angle, and a viewer that drew it as a position would show a
marker that never moves and no line at all. The position survives the same way.

### Keyword matching

Keywords longer than four characters match as substrings. Shorter ones — `doa`,
`lob`, `aoa`, `id` — match only whole tokens, where an identifier is split on
separators and camelCase humps. Without that, `globe` contains `lob`, `payload`
contains `aoa`, and half the fields in any schema contain `id`.

Keyword lists are ordered, and the order is a preference list. `entity`, for
instance, tries `mmsi` before `id`, which is the difference between keying an
AIS stream by the vessel and keying it by the message type.

---

## Entity keys

Some datastreams carry many real-world objects. One AIS `vesselLocation` stream
describes every ship in range, and consecutive observations are different
vessels — so "the latest observation" is not a position, it is whichever ship
last transmitted.

`EntityKeyInference.entityKeyPath` finds the Text or Category leaf that names
the object, and `SystemLiveSession` buckets observations by its value. Streams
with no key use `""` as their single bucket, so no consumer needs an optional
dimension.

Only `.location` and `.target` streams are grouped. Every stream has an
identifier somewhere — a serial number, a station name, a channel — and
splitting a weather station's readings by its own serial number produces one
bucket and a lot of ceremony. A target stream is grouped because one range
finder designates many targets and only the latest per target belongs on the
map; its `sourceIdPath` is excluded from the candidates, since that field names
who was looking rather than what was looked at.

---

## Embedded positions

`RemoteDatastream.embeddedPosition` is computed for *every* datastream whose
record contains a location vector anywhere, at any depth, and is nil when the
role is already `.location` (there the position is the role).

This is how a system that publishes no position output still lands on the map.
`LocationPaths.resolve` searches recursively — breadth before depth, so a
top-level fix still wins — which is what finds KrakenSDR's
`/stationConfig/location`. The heading beside it, `/stationConfig/heading`, is
found by `HeadingPath.resolve`, which looks among the vector's **siblings**
first and only then at the record's top level: a heading belongs to the position
it was measured with.

---

## Where a marker's coordinates come from

`RemoteSystem.PositionKind`, best first:

| Kind | Source | Marker treatment |
|---|---|---|
| `.live` | a `.location` datastream | full-colour glyph, rotated by heading |
| `.reported` | some datastream's `embeddedPosition` | full-colour glyph with an antenna badge, rotated |
| `.deployed` | the system resource's own geometry | muted glyph, pinned, never rotated |

A system with more than one source uses the best one it has. A deployed marker
never rotates: the system record carries a point, not an attitude.

### Heading, in order of preference

1. The location stream's own heading path (`TrueHeading`, then `Heading`, then
   course over ground).
2. The embedded position's heading path — KrakenSDR's array bearing.
3. A **single** `.orientation` stream on the same system. This is how an Android
   phone's separate `gps_data` and `euler_orientation_data` outputs become one
   rotated marker. More than one attitude output and there is no basis for
   choosing, so the marker stays unrotated.

---

## Targets: where the line starts

A `.target` stream gives the map a point and nothing else. The line worth
drawing runs from the system that *observed* the target to the target itself,
and finding that system is `TargetSourceResolver`'s whole job. It is a pure
function of the loaded `[RemoteSystem]`, this device, and the observation.

Four rules, in descending order of how much the node actually said:

| # | Rule | Fires when |
|---|---|---|
| i | `.identifier` | the record has a source-identifier field (Text/Category matching source/origin/observer/platform/system/uid) whose value matches a system's id, uid or name — case-insensitively, and also when it is a **suffix** of the uid, since a driver usually writes the tail it knows (`…:android:1234`). This device is a candidate like any other system. |
| ii | `.parent` | the target stream's system carries `parent@id` and that parent is loaded. |
| iii | `.owner` | the target stream's own system has a position (`hasPosition`). This is the common shape: the driver publishes the target output on the phone's own system. |
| iv | `.uidAffinity` | another **positioned** system's uid shares a token of eight characters or more with the owner's. Ranked by how many colon-separated segments the two share, then by which candidate's uid says the least beyond them — the reference node carries two registrations of the same phone, and both halves of that ordering are what pair each range finder with the right one. |
| — | `.ownerWithoutPosition` | nothing above placed a source: the target marker is drawn, no line is, and the map logs it once per (datastream, source) at debug. |

Rule iv is not something a Connected Systems node states, and it is the
fallback for a reason: on the reference node the range finder registers as
`urn:lasertech:trupulse360:7ae57419dd427e4c:replay`, the phone carrying it as
`urn:osh:android:7ae57419dd427e4c:droid2:replay`, and the sixteen-character
device id is the only thing connecting them — no parent link, no subsystem
entry, no identifier in the record. It is consulted **only** when the owner has
no position of its own, so it can never override anything the node said, and
locatability is read from `hasPosition` rather than from the caller's position
lookup so the choice of system stays a pure function of the list.

`SourceRef` carries the source's *current* coordinate, filled in by a `position`
closure the caller supplies — `COPMapModel` passes its live/reported/deployed
lookup, which is the same answer the source's own marker gets. So the line's
origin follows the source when it moves, and the whole overlay is rebuilt by
calling the resolver again rather than by invalidating anything.

### What gets drawn

| Thing | Treatment |
|---|---|
| target marker | `plus.viewfinder`, red, never rotated, label = "412 m @ 087°" when the record carries range/azimuth, `ActivityDot` from the stream's freshness |
| target line | a straight `MapPolyline` from the source's current position, red, 2 pt, translucent. Both ends are known, so no geodesy is needed — unlike a LOB, which is a ray and is projected on the sphere |
| fade | `TargetStyle.opacity`, on `BearingStyle.staleAfter`: faded after 60 s, **never removed**. A designation is an event, and "the last target, an hour ago" is the answer |
| history | one dot per past observation, last 20, no lines, behind the "Target history" layer toggle (off by default) |
| card | `TargetSummaryView`: range, azimuth, elevation, target lat/lon, the source's name, and a prominent "as of". Tapping the source name sends the user to the map with that marker selected, via `TabRouter.showOnMap(markerId:)` |

Only the latest target per (datastream, entity) is drawn, which falls out of
`SystemLiveSession.entities(datastreamId:)` — older designations are dropped
from the live layer and are reachable only through the history layer.

`SystemLiveSession` bootstraps a `.target` stream with `limit: 1` of any age,
the same plan a `.bearing` stream gets and for the same reason: a range finder
fires when someone pulls the trigger.

---

## Extending this

**A new role.** Add a case to `DatastreamRole`, a rank to its `priority`, a
label, a glyph in `SystemGlyph`, and a body in `DatastreamCard.roleBody(for:)`.
Insert the detection into `DatastreamRoleInference.role` at the position its
specificity earns — a rule that fires on a keyword belongs *after* one that fires
on structure. Then add a fixture-backed assertion to `DatastreamRoleTests`:
every rule in the table above has one, and a rule without one drifts.

**A new keyword.** Add it to the right list in `DatastreamRoleInference.Keywords`
and mind the order — earlier means preferred. Anything four characters or
shorter is matched as a whole token, so check that the tokeniser splits the
identifiers you expect (`raw_lob` → `raw`, `lob`).

**A new position source.** Add a case to `PositionKind`, place it in
`RemoteSystem.positionKind` by how much evidence it represents, and give it a
marker treatment in `MarkerView`. Every consumer reads the enum rather than
re-deriving the source, so nothing else has to change.

**A rule that gets it wrong on your node.** Run the live-node test — it prints a
table of every datastream and the role it was given:

```sh
TEST_RUNNER_OSH_NODE=http://host:8080/sensorhub/api \
  xcodebuild test -scheme osh-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:osh-iosTests/LiveNodeViewerTests
```

`targetStreamDrawsALineFromItsSource` in that suite prints, per target stream,
which rule placed the source, where it put it, and how far the source is from
the target — which is how a source-resolution rule that gets it wrong on your
node is found.


---

## Commands: PTZ detection

The command side reads a control stream's parameters schema the same way the
observation side reads a record schema — from what the schema *says*, never from
a driver name. `PTZCapability.detect(in:controlStreamId:)` is the whole rule set.

**The structure.** The root must be a `DataChoice`, either directly or as the
single field of the record `SWESchemaDecoder` wraps a non-record root in. A
choice is the right shape because a command selects exactly one thing to do.

**The items**, matched by definition first and by name only when the component
declares no definition at all. A definition that exists and disagrees is the
author being explicit, and a name must not override it.

| Slot | Definition contains | Name |
|---|---|---|
| `relativePan`  | `RelativePan`  | `rpan` |
| `relativeTilt` | `RelativeTilt` | `rtilt` |
| `relativeZoom` | `RelativeZoom` | `rzoom` |
| `absolutePan`  | `Pan`, and **not** `Relative`        | `pan` |
| `absoluteTilt` | `Tilt`, and **not** `Relative`       | `tilt` |
| `absoluteZoom` | `ZoomFactor`, and **not** `Relative` | `zoom` |
| `preset`       | `Preset`, on a `Text` item           | `preset` |
| `position`     | a `DataRecord` whose fields resolve to all three absolute axes | — |

The relative rules are tested before the absolute ones, and the absolute ones
refuse anything the schema calls relative. Both halves of that matter:
`RelativePan` contains `Pan`, so an implementation that checked absolute first
would swallow every relative axis and draw a D-pad that issued absolute moves.

**Ranges** come from `AllowedValues.intervals` — the first interval only. A
component with several disjoint intervals cannot drive one slider, and
pretending the union is a range would let the UI offer values the camera will
refuse. The reference Axis camera bounds pan to `[-180, 180]`, tilt to
`[-90, 0]` and zoom to `[1, 9999]`, and declares no bounds at all on its
relative axes — which is why the step size is the app's choice and not the
schema's.

**The refusal.** `detect` returns nil unless a *pair* of pan and tilt axes
exists, relative or absolute. A lone zoom control is a zoom control; calling it
a PTZ camera and drawing a pad for it would be a lie the user discovers by
pressing a button that does nothing. Everything that fails detection gets its
parameter tree read-only on the dashboard instead.

**Extending it.** A new command family is a new type beside `PTZCapability`, not
a case inside it: detection, the controls and the parameter builder travel
together, and `ControlStreamCard` chooses between them the way `DatastreamCard`
chooses a role body. Add fixture-backed assertions to `PTZCapabilityTests` —
including a negative one, because a detector that never says no is not a
detector.
