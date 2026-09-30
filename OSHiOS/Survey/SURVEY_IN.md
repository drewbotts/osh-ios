# Survey-In: positioning a remote system from the phone

Pass 4. A user stands at a system that has no GPS or IMU of its own — the Axis
PTZ on the Raspberry Pi node is the motivating case — and writes the phone's
averaged position and true heading into that system's SensorML description.
Nothing is posted as an observation; a static emplacement is a property of the
system.

## Two write paths — both through datastreams

`SurveyWriteStrategy.detect` picks one per system:

1. **Static outputs** — when the system has a `sensorLocation` datastream (vector
   defined as `…/OGC/0/SensorLocation`) and, optionally, a `sensorOrientation`
   one (`…/OGC/0/SensorOrientation`, Euler, NED). These are what osh-core's
   `AbstractSensorModule` publishes for a driver configured with a Position.
   One swe+json observation is posted to each, built from the stream's own
   schema (`SurveyObservationBody`), then the newest record of each is re-read
   and compared. The live `sensorOrientationPtz` stream shares the orientation
   definition and is excluded by name.
2. **Create outputs** — otherwise. The two datastreams are created on the
   system (`POST /systems/{id}/datastreams`) in the driver's exact shape
   (`SurveyOutputSchemas`: same names, definitions, labels, axis ids, EPSG 4979
   and NED frames), resolved back from the node, and then written to as in 1.
   The system description is never touched.

### The node must be able to write to the system

Verified 2026-09-16 on a local copy of the osh-node RDK 1.0.5 build (osh-core
2.0.2), and by read-only probes plus one no-change POST on the Pi:

| write | system in the API's write DB | system not in it |
|---|---|---|
| `POST /datastreams/{id}/observations` on a driver's `sensorLocation` | **201**, record listed | 400 "Resource is not writable" (Pi: same, as admin) |
| `POST /systems/{id}/datastreams` (new `sensorOrientation`) | **201**, `Location: /datastreams/{new}` | 500 (null system handler) |
| `PUT /systems/{id}` SensorML | 204 | 404 "Resource not found" (Pi: same) |

The API writes through one database module (`ConSysApiServiceConfig.databaseID`,
the "Connected Systems Database"). `DefaultSystemRegistry` places a driver's
system in that module only when the module's `systemUIDs` contains the UID (or a
wildcard matching it — `MapWithWildcards`); otherwise the driver goes to the
default state database (#0), which the API can read through the federated view
but never write. `ObsHandler` then answers `ServiceErrors.notWritable()`
because `SystemDatabaseTransactionHandler.getDataStreamHandler` finds no
handler in the write DB; `DataStreamHandler.addEntry` dereferences the null
system handler (500); `SystemHandler.updateEntry` reports not found (404).

**On the Pi today** the Axis cameras (`urn:axis:cam:*`), DR-CAMERA
(`urn:uuid:…`) and the other drivers are in the default database, so every
write to them is refused with the answers above. The fix is node configuration:
Admin UI → Databases → Connected Systems Database → System UIDs → add
`urn:axis:cam:*`, the DR-CAMERA UID, etc. → restart. Once done, both paths work
as in the left column (proved on the local copy with the FakeWeather driver:
obs 201, datastream 201, and the description PUT 204 too). The app's failure
screen says exactly this.

## The description exchange (not wired — kept for reference)

`SensorMLPositionPatch` and `OrderedJSON` implement a read-modify-write of the
SensorML `position` and are unit-tested, but no longer used by the survey: a
PUT replaces the whole description, which is not what positioning a driver's
camera should do.

```
GET  /systems/{id}?f=application/sml+json      Accept: application/sml+json
     → the PhysicalSystem document, verbatim
edit → replace or insert the "position" member (SensorMLPositionPatch)
PUT  /systems/{id}                              Content-Type: application/sml+json
     → 204 No Content
GET  /systems/{id}?f=application/sml+json      → re-read; the pose must match
```

The `f` query parameter is required. With `Accept: application/sml+json` alone
the reference node (osh-core 2.0.2, checked 2026-09-15) answers the **GeoJSON
Feature** under `Content-Type: auto`; editing that document would put a
`position` on a Feature and the PUT would answer 400. `?f=sml3` is the short
form the node's own alternate links use; `f=application%2Fsml%2Bjson` works
too and is what the client sends (the `+` percent-encoded — see
`URLComponents+MediaType.swift`).

## The position element

Mirrors what the node writes for a driver configured with a location and an
orientation (the Axis PTZ, `02luf9f2mgag`, fixture `survey-in/system-sml.json`):

```json
"position": {
  "type": "GeoPose",
  "referenceFrame": "http://www.opengis.net/def/crs/EPSG/0/4979",
  "ltpReferenceFrame": "http://www.opengis.net/def/cs/OGC/0/NED",
  "position": { "lat": 34.7250123, "lon": -86.5830456, "h": 212.34 },
  "angles":   { "yaw": 217.5, "pitch": 1.25, "roll": -0.5 }
}
```

Read from the node's own bindings (`SMLJsonBindings.readPosition`,
`GeoPoseJsonBindings.readPose` in sensorml-core / swe-common-om 2.0.2):

- `type` **must be the first key** of the position object (`beginObjectWithType`),
  and must be `GeoPose`, `RelativePose` or `Point`. Anything else is a 400.
- Inside a GeoPose the reader accepts `referenceFrame`, `ltpReferenceFrame`,
  `localFrame`, `position` (`lat`/`lon`/`h` or `x`/`y`/`z`), and `angles`
  (`yaw`/`pitch`/`roll`) or `quaternion` (`x`/`y`/`z`/`w`), in any order,
  skipping unknown keys.
- The writer omits `referenceFrame` for a GeoPose and defaults it to
  `OGC/0/CRS84h` on read — WGS 84 with **ellipsoidal** height, the same datum as
  EPSG 4979. The explicit 4979 tag is therefore accepted but not echoed back;
  the round-trip check compares lat/lon/h/angles, not the frame string.
- `ltpReferenceFrame` is written **NED**, as the node writes for its own
  drivers (`GeoPosHelper.newEulerOrientationNED`). In NED, `yaw` is a compass
  heading: degrees clockwise from true north. In the GeoPose default (ENU) it
  is not. The Axis description on the node says NED; so does ours.
- `h` is HAE — `CLLocation.ellipsoidalAltitude` — never `CLLocation.altitude`
  (MSL). Both are shown on the review screen, labelled.

Everything else in the description is preserved in content and key order
(`OrderedJSON`). The node's parser needs `type` first in every object; a
Dictionary-based edit would have reordered the whole document.

## What the node does with a PUT (verified on a local 2.0.2 node)

`SystemHandler.updateEntry` wraps the parsed description with `hideOutputs()`,
`hideTaskableParams()` and `defaultToValidFromNow()`, then
`SystemTransactionHandler.update`:

- `outputs` and taskable `parameters` in the body are ignored — the node
  regenerates them from its datastreams and control streams. Sending them
  back is harmless.
- If the body's `validTime` begins at the same instant as the stored version,
  that version is **replaced in place**. A later begin adds a new version to
  `/systems/{id}/history`; an earlier one is refused ("A version of the system
  description with a more recent valid time already exists"). Preserving the
  node's own `validTime` — which the patch does — means one version, edited.
- The GeoJSON `geometry` is derived from the position (`Pose.toLocation()`),
  so `GET /systems/{id}` as geo+json shows the new point immediately. That is
  what `RemoteSystem.fixedLocation` and the map's deployed pin read.

Verified 2026-09-15 against a local copy of the osh-node RDK 1.0.5 build
(same 2.0.2 jars as the Pi), port 18080:

| system | how it got there | `PUT /systems/{id}` |
|---|---|---|
| `040g`, registered via `POST /systems` as this app registers itself | API | **204**, position round-trips, geometry updated |
| `03cu5rs4h0hg`, a FakeWeather driver module with a configured location | driver | **404** `{"status":404,"message":"Resource not found: 03cu5rs4h0hg"}` — GET of the same id answers 200 |
| any, position with `type` not first | — | 400 |
| any, no `Content-Type` | — | 400 |
| any, the GeoJSON Feature sent as sml+json | — | 400 |

The 404 is not an id problem. `SystemHandler.updateEntry` resolves the id in
the API's *write* database (`SystemDatabaseTransactionHandler.getSystemHandler`)
and returns false when it is not there, which `BaseResourceHandler.update`
reports as not found. A system a driver module registered is not in that set;
its description is owned by the driver and is regenerated from the driver's
configuration (Admin UI → module → Position) on every start.

**Consequence for the reference node:** the Axis PTZ, DR-CAMERA and the other
driver-registered systems there are expected to answer 404 to this PUT. The
app reports the exact request and response and explains the 404 in place; it
does not fall back to anything. Systems this app (or any API client) registered
can be surveyed in.

## Height

The written height is a chosen base plus a mount offset. The base is HAE by
default — the slot is defined as ellipsoidal height in both paths (EPSG 4979 in
the GeoPose, `HeightAboveEllipsoid` in the driver's location vector) — or MSL
when the user chooses it, which the review screen flags as a deliberate datum
mismatch. The mount offset (±50 m, 0.1 m) is the height of the mount above the
phone.

## Measurement

- Position: 5 s of `CLLocation` fixes (`SurveyInController.captureDuration`),
  accuracy-weighted (1/σ², σ floored at 1 m); longitude via a circular mean.
  The quoted accuracy is the weighted mean of the fixes' own accuracies, not
  √(1/Σw) — consecutive fixes from a stationary receiver are not independent.
- Heading: `CMDeviceMotion.heading` in `.xTrueNorthZVertical` at 20 Hz,
  circular mean over the capture, spread as the circular standard deviation.
  `CLHeading.headingAccuracy` and `CMDeviceMotion.magneticField.accuracy` are
  shown live; a poor reading warns and points at the manual adjustment.
- Review: heading ±30° at 0.5°, editable HAE, editable pitch/roll (default 0,
  with the phone's own figures one tap away). Nothing is sent until "Write".
- PTZ: the schema's absolute `ptzPos` (pan 0, tilt 0, zoom 1) is preferred as
  the pan-zero reference; separate absolute axes next; a preset named
  home/reset/… next; an open preset field guesses "Home" and says so
  (`PTZHomePlan`).

## Open questions for the field test

The "Heading sources" disclosure on the alignment screen shows three headings
side by side — `CMDeviceMotion.heading` (used), the −yaw formula the publisher
uses, and `CLHeading.trueHeading`. Which of them lines up with a lens when the
phone is held flat versus upright is a question for the phone, not the
simulator; the publisher's −yaw formula is not changed by this pass.
