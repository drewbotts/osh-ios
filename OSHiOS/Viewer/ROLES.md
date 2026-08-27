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
| 2 | `.location` | a Location vector resolves, and the record is neither settings-flavoured (rule 6) nor bearing-flavoured (rule 4) | `LocationPaths` + an optional heading path |
| 3 | `.orientation` | a Vector or record defined as Orientation/Quaternion, or a heading+pitch+roll triple | `OrientationPaths` (quaternion or Euler) |
| 4 | `.bearing` | a Quantity leaf matching a direction-finding keyword | the angle path + an optional quality path |
| 5 | `.chart` | a numeric DataArray that is variable-size or ≥8 elements | the series paths + an optional x-axis |
| 6 | `.status` | settings-flavoured: a name or definition containing settings/config/status, or ≥3 nested records with ≤1 top-level Quantity | — |
| 7 | `.timeseries` | at least one Quantity or Count alongside a Time | — |
| 8 | `.generic` | nothing else matched | — |

`.generic` is not a failure. It renders as labelled rows of whatever decoded,
which is why no stream on any node is ever unviewable.

### Two exclusions on rule 2

The ordering above says location is decided before bearing, and rule 2 carries
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

Only `.location` streams are grouped. Every stream has an identifier somewhere —
a serial number, a station name, a channel — and splitting a weather station's
readings by its own serial number produces one bucket and a lot of ceremony.

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
marker treatment in `HeadingMarker`. Every consumer reads the enum rather than
re-deriving the source, so nothing else has to change.

**A rule that gets it wrong on your node.** Run the live-node test — it prints a
table of every datastream and the role it was given:

```sh
TEST_RUNNER_OSH_NODE=http://host:8080/sensorhub/api \
  xcodebuild test -scheme osh-ios \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:osh-iosTests/LiveNodeViewerTests
```
