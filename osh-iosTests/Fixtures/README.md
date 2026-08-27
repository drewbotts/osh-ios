# Fixtures

Documents captured verbatim from a live OpenSensorHub Connected Systems node by
`scripts/capture-fixtures.sh`. **The test suite runs from these files alone**;
no test in the default run touches a network. Tests that do talk to a node are
skipped unless `OSH_NODE` is set.

Recapture with:

```sh
OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh survey
OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh capture

# one folder only, leaving the committed rest untouched
OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh capture kraken-doa
```

`capture` is idempotent and re-runs `scripts/sync-fixture-membership.py`
afterwards, so adding a fixture folder needs no hand-editing of the Xcode
project. `survey` prints the node's systems, datastreams and component types
without writing anything.

## Layout

One folder per captured datastream. Every file is the node's response body,
unmodified.

| File | Endpoint |
|---|---|
| `datastream.json` | `GET /datastreams/{id}` |
| `schema-json.json` | `GET /datastreams/{id}/schema?obsFormat=application/swe+json` |
| `schema-binary.json` | `GET /datastreams/{id}/schema?obsFormat=application/swe+binary` |
| `obs-json.json` | `GET /datastreams/{id}/observations?f=application/swe+json&limit=3` |
| `obs-omjson.json` | `GET /datastreams/{id}/observations?f=application/om+json&limit=3` |
| `obs-binary.bin` | three messages, concatenated |
| `obs-binary.index.json` | each message's byte length, and where it came from |
| `system.json` | `GET /systems/{id}` |
| `subsystems.json` | `GET /systems/{id}/subsystems`, only when non-empty |
| `controlstreams.json` | `GET /systems/{id}/controlstreams` |
| `control-schema.json` | `GET /controlstreams/{id}/schema?commandFormat=…` |

A file is **absent when the node did not serve it**, and that absence is itself
under test — `video-mjpeg` has no `schema-json.json` because the node answers
400 for it, which is exactly the case a viewer has to handle.

`obs-binary.bin` is a bare concatenation with no delimiters, so
`obs-binary.index.json` is what makes it splittable. Its `source` records
whether the messages came from the live WebSocket stream (frame-aligned, one
message per length) or from REST, where lengths were recovered by differencing
successive `limit=N` responses because the datastream is archive-only.

## What each folder covers

| Slug | Datastream | Why it is here |
|---|---|---|
| `weather` | Tempest Observation | plain scalar record — Quantity, Count, Text |
| `ais-vessel-location` | AIS vesselLocation | Boolean, Category, Text, Count, Vector, `nilValues` |
| `spectrum-array` | KrakenSDR Spectrum | two variable-size DataArrays sized by `elementCount` href |
| `video-mjpeg` | Axis PTZ video1 | nested DataArray delivered as one JPEG block; no swe+json schema |
| `gps` | Android gps_data | Time + Vector — the shape this app itself writes |
| `kraken-settings` | KrakenSDR settings | deeply nested DataRecord; a position at `/stationConfig/location` with a heading beside it |
| `kraken-doa` | KrakenSDR DoA | a line of bearing with a confidence figure, and the station's own position stamped on every record |
| `choice-ptz-control` | Axis ptzControl | the node's only DataChoice; seeds Pass 4 |

## Not represented on this node

- **Subsystems.** All eleven systems answer `/subsystems` with an empty
  collection and none carries a parent link, so no `subsystems.json` exists.
- **A DataChoice with messages.** The PTZ control stream has zero archived
  commands, so the binary choice-selector layout could not be verified against
  real bytes. See `OSHiOS/SWE/Decode/BINARY_FORMAT.md`.
- **A system with a geometry.** Not one of the node's systems carries a point in
  its registration or its sampling features, so `PositionKind.deployed` — the
  static "installed here" marker — has no fixture behind it and is covered by
  the synthetic cases in `RemoteSystemTests`.
- **Matrix, Geometry, the Range types, and the unsigned and short integer
  dataTypes.** The decoder handles them; no fixture exercises them, and the
  synthetic tests in `SWEBinaryFormatTests` cover them instead.
