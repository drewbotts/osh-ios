# Commanding a Connected Systems node

Everything here was determined **empirically** against the reference node at
`http://192.168.4.34:8080/sensorhub/api` on 2026-08-27, commanding the Axis PTZ
camera (`urn:axis:cam:E82725115276`). Nothing was taken from a specification,
because the node serves no OpenAPI document this client can reach:
`/api/openapi`, `/api/api-docs` and `/api/openapi.json` answer 400 or 401.

Nothing below is redacted. The node is on a LAN, it accepts anonymous requests,
and a fixture nobody can reproduce is not a fixture.

## The one header that is not optional

Every request carries `Accept: application/json`. Without it the node serves its
HTML admin console for these paths, and the console demands a login the API does
not:

```
$ curl -s -o /dev/null -w '%{http_code}' 'http://192.168.4.34:8080/sensorhub/api/systems'
401
$ curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' \
    'http://192.168.4.34:8080/sensorhub/api/systems'
200
```

A 401 from this node is very often a missing `Accept`, not a missing password.

## Discovery

```
GET /systems/{systemId}/controlstreams        → { "items": [ ... ] }
GET /controlstreams/{id}/schema               → the parameters schema
GET /controlstreams/{id}/commands?limit=N     → commands already issued
```

The schema resource answers in two shapes depending on `commandFormat`, and they
are the same document under two different wrapper keys:

| Query | Top-level keys |
|---|---|
| *(none)* or `?commandFormat=application/json` | `commandFormat`, `parametersSchema` |
| `?commandFormat=application/swe%2Bjson` | `paramsSchema` |

`SWESchemaDecoder` accepts `recordSchema`, `paramsSchema` and
`parametersSchema`; `ConnectedSystemsReadClient.getControlSchemaJSON` asks for
`application/swe+json` and falls back to the default.

> The `+` **must** be percent-encoded as `%2B`. A literal `+` decodes to a space
> in a query string and the node answers 400. See `URLComponents+MediaType.swift`.

The swe+json response for this camera is byte-identical to the captured fixture
`osh-iosTests/Fixtures/choice-ptz-control/control-schema.json`.

## Issuing a command

```
POST /controlstreams/{id}/commands
Content-Type: application/json
Accept: application/json
```

### Request

The parameters schema is a `DataChoice`, and a choice selects exactly one item.
On the wire that item is the sole key of the `parameters` object:

```json
{"parameters":{"rpan":3.0}}
```

`issueTime` is accepted and optional. When present it comes first:

```json
{"issueTime":"2026-08-27T21:10:00Z","parameters":{"rzoom":0.0}}
```

There is **no** `control@id` in the body; the control stream is identified by
the URL.

### Response — 200

```json
{
  "command@id": "025svjetu8qg1tucoba0cd72922g",
  "reportTime": "2026-08-27T21:04:55.949625665Z",
  "statusCode": "COMPLETED",
  "executionTime": [
    "2026-08-27T21:04:55.949620516Z",
    "2026-08-27T21:04:55.949620516Z"
  ]
}
```

The node executes synchronously here: the response already says `COMPLETED`.

### Response — 400

An item name outside the choice:

```
POST {"parameters":{"bogusItem":1}}
```
```json
{
  "status": 400,
  "message": "Invalid payload: Invalid JSON: Invalid choice selector value: bogusItem at $.parameters.bogusItem"
}
```

An incomplete record — `ptzPos` with only `pan`:

```
POST {"parameters":{"ptzPos":{"pan":0.0}}}
```
```json
{
  "status": 400,
  "message": "Invalid payload: Invalid JSON: java.lang.IllegalStateException: Expected a name but was END_OBJECT at line 1 column 36 path $.parameters.ptzPos.pan"
}
```

That second error is the reason `CommandBody` builds ordered strings rather than
encoding a dictionary. The node's reader walks the record in the order the
schema declares — `pan`, `tilt`, `zoom` — and stops at the first field that is
not where it expected it. A reordered or partial record is a 400, not a
best-effort move.

## Command values, by item type

| Schema item | Type | JSON |
|---|---|---|
| `rpan`, `rtilt`, `rzoom`, `pan`, `tilt`, `zoom` | Quantity | `{"rpan":3.0}` |
| `preset` | Text | `{"preset":"Home"}` |
| `ptzPos` | DataRecord | `{"ptzPos":{"pan":0.0,"tilt":-30.0,"zoom":1.0}}` |

Whole numbers are written with a `.0`. Not required by JSON — the node accepts
`3` — but it is how the node echoes them back in its own listing, which keeps a
captured request and a captured response comparable by eye.

## Reading a command's status

There is no per-command resource:

```
GET /controlstreams/{id}/commands/025svjetu8qg1tucoba0cd72922g
  → 404 {"status":404,"message":"Resource not found"}
GET /controlstreams/{id}/commands/{cmdId}/status
  → 404 {"status":404,"message":"Resource not found: 025svjetu8qg1tucoba0cd72922g"}
GET /commands/{cmdId}
  → 400 {"status":400,"message":"Invalid resource name: 'commands'"}
```

Status lives only in the collection, so `CommandClient.getCommandStatus` lists
and matches on `id` — and the collection retains exactly **one** command per
control stream, the most recent. Asking for the status of anything older is a
miss, not an error, which is why `getCommandStatus` returns an optional and why
the live test only ever looks up the last command it sent:

```
$ curl -s -H "$H" "$BASE/controlstreams/03tdn85sv0r0/commands?limit=100" | jq '.items | length'
1
```

A listing looks like this:

```json
{
  "items": [
    {
      "id": "025svjetu8qg10mdoba0c4tvar10",
      "controlstream@id": "025svjetu8qg",
      "issueTime": "2026-08-27T21:05:06.331306690Z",
      "sender": "anonymous",
      "currentStatus": "COMPLETED",
      "parameters": { "rpan": -3.0 }
    }
  ]
}
```

`sender` is `"anonymous"` for an unauthenticated command and the username
otherwise — the earlier `rtilt` command on this stream records `"admin"`.

## Two PTZ cameras

The reference node carries two, and both are recognised from their schemas
alone:

| System | Control stream | D-pad | Absolute | Preset |
|---|---|---|---|---|
| `02luf9f2mgag` Axis PTZ | `025svjetu8qg` | yes | yes | yes |
| `03qqv3mtk41g` Axis Video Camera 2 | `03tdn85sv0r0` | yes | yes | yes |

Six control streams exist across the node in total; every one of them decodes.

## The verification run

Authorised small relative moves only, ending where they started. The camera's
`ptzOutput` datastream (`02sfpq7ju5ng`) reports the position, so the move is
observable rather than merely accepted.

| # | Request | HTTP | `ptzOutput` after |
|---|---|---|---|
| 0 | — | — | `{"pan":0.0,"tilt":60.0,"zoomFactor":1.0}` |
| 1 | `{"parameters":{"rpan":3.0}}` | 200 `COMPLETED` | `{"pan":3.0,"tilt":60.0,"zoomFactor":1.0}` |
| 2 | `{"parameters":{"rpan":-3.0}}` | 200 `COMPLETED` | `{"pan":0.0,"tilt":60.0,"zoomFactor":1.0}` |
| 3 | `{"issueTime":"…","parameters":{"rzoom":0.0}}` | 200 `COMPLETED` | unchanged |

The pan value moved by exactly the commanded three degrees and came back, which
is what makes this a verification rather than a 200.

`LiveCommandTests.relativePanRoundTrip` repeats this from inside the app's own
client, against whichever PTZ camera the node offers first. Its captured run
against Axis Video Camera 2 (`03tdn85sv0r0`, `ptzOutput` `02gu5q72u16g`):

```
Start position: 130.0
POST {"parameters":{"rpan":3.0}}
→ HTTP 200 {"command@id":"03tdn85sv0r01ev1oba0c44sgo50",
            "reportTime":"2026-08-27T21:48:43.516605799Z",
            "statusCode":"COMPLETED",
            "executionTime":["2026-08-27T21:48:43.516600133Z",
                             "2026-08-27T21:48:43.516600133Z"]}
Position after +3.0°: 133.0
POST {"parameters":{"rpan":-3.0}}
Position after return: 130.0
Command 03tdn85sv0r01fn1oba0c8gq8gmg status: COMPLETED
```

One trap that run exposed: `fetchMostRecent` searches backwards from the range
end the *datastream summary* reports, and the whole point of the test is to make
an observation land after that end. The summary has to be re-fetched on each
read or the check looks in a window that closes before the move it is
looking for.

Note that the camera *reports* `tilt: 60.0` while its schema constrains a
commanded `tilt` to `[-90, 0]`. The output and the input use different
conventions; the app never assumes a reported value can be fed back as an
absolute command, and the absolute panel is driven from the schema's own ranges.

## Reproducing

```sh
BASE=http://192.168.4.34:8080/sensorhub/api
H='Accept: application/json'

curl -s -H "$H" "$BASE/systems/02luf9f2mgag/controlstreams"
curl -s -H "$H" "$BASE/controlstreams/025svjetu8qg/schema?commandFormat=application/swe%2Bjson"

curl -s -X POST "$BASE/controlstreams/025svjetu8qg/commands" \
  -H 'Content-Type: application/json' -H "$H" \
  --data '{"parameters":{"rpan":3.0}}'

curl -s -H "$H" \
  "$BASE/datastreams/02sfpq7ju5ng/observations?f=application%2Fom%2Bjson&limit=3&phenomenonTime=latest"
```
