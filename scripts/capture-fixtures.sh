#!/usr/bin/env bash
#
# capture-fixtures.sh — survey an OpenSensorHub Connected Systems node and
# capture test fixtures for the SWE Common decoder (Pass 3a).
#
# Usage:
#   OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh survey
#   OSH_NODE=http://host:8080/sensorhub/api ./scripts/capture-fixtures.sh capture
#
# Auth: if OSH_TEST_USER and OSH_TEST_PASS are set they are used as HTTP Basic
# credentials on every request; otherwise requests are sent anonymously. The
# values are never written to any output file.
#
# Idempotent: re-running overwrites the fixture folders in place.
#
# Requires: bash, curl, python3 (standard library only — no pip, no venv).

set -uo pipefail

OSH_NODE="${OSH_NODE:-}"
OSH_NODE="${OSH_NODE%/}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_ROOT="$REPO_ROOT/osh-iosTests/Fixtures"

MODE="${1:-survey}"

# Only the modes that talk to a node need one; "sync" is purely local.
if [[ "$MODE" != "sync" && -z "$OSH_NODE" ]]; then
  echo "error: OSH_NODE is not set" >&2
  exit 2
fi

# Export for the embedded python3 programs. OSH_TEST_USER/OSH_TEST_PASS are
# already in the environment when set; python reads them directly and puts them
# only into an in-memory Authorization header.
export OSH_NODE FIXTURE_ROOT

# ─────────────────────────────────────────────────────────────────────────────
# Shared python helper: HTTP + node conventions.
#
# Two node conventions this script must respect, both discovered against a live
# node and both easy to get wrong:
#   1. obsFormat/commandFormat values contain a "+", which decodes to a space in
#      a query string. They must be percent-encoded as %2B or the node answers
#      400/302.
#   2. /systems/{id}/controlstreams is the control endpoint; /controls redirects.
# ─────────────────────────────────────────────────────────────────────────────
read -r -d '' PY_COMMON <<'PY'
import base64, json, os, sys, urllib.parse, urllib.request

BASE = os.environ["OSH_NODE"]
_user = os.environ.get("OSH_TEST_USER")
_pass = os.environ.get("OSH_TEST_PASS")
_AUTH = None
if _user and _pass:
    _AUTH = "Basic " + base64.b64encode(f"{_user}:{_pass}".encode()).decode()

def request(path, accept=None, timeout=30):
    """GET BASE+path. Returns (status, bytes). Never raises on HTTP status."""
    req = urllib.request.Request(BASE + path)
    if _AUTH:
        req.add_header("Authorization", _AUTH)
    if accept:
        req.add_header("Accept", accept)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        print(f"  ! {path}: {e}", file=sys.stderr)
        return 0, b""

def get_json(path):
    status, body = request(path)
    if status != 200:
        return None
    try:
        return json.loads(body)
    except Exception:
        return None

def q(value):
    """Percent-encode a media type so its '+' survives the query string."""
    return urllib.parse.quote(value, safe="")

def items(doc):
    if doc is None:
        return []
    if isinstance(doc, list):
        return doc
    return doc.get("items", [])

def component_types(node, acc=None):
    """Every SWE 'type' appearing anywhere in a component tree."""
    acc = set() if acc is None else acc
    if not isinstance(node, dict):
        return acc
    if node.get("type"):
        acc.add(node["type"])
    for key in ("fields", "field", "coordinates", "coordinate", "items", "item"):
        for child in node.get(key) or []:
            component_types(child, acc)
    for key in ("elementType", "choiceValue", "elementCount"):
        if key in node:
            component_types(node[key], acc)
    return acc
PY

# ─────────────────────────────────────────────────────────────────────────────
# Survey
# ─────────────────────────────────────────────────────────────────────────────
do_survey() {
python3 - <<PY
$PY_COMMON

systems = items(get_json("/systems?limit=200"))
print(f"Node: {BASE}")
print(f"Systems: {len(systems)}\n")

hdr = (f"{'SYSTEM':<24} {'SYS ID':<13} {'DATASTREAM ID':<13} "
       f"{'OUTPUT NAME':<26} {'BIN':<4} {'COMPONENT TYPES':<44} TOP-LEVEL FIELDS")
print(hdr)
print("-" * len(hdr))

for s in systems:
    props = s.get("properties", s)
    sid = s.get("id", "")
    sname = (props.get("name") or "?")
    subs = items(get_json(f"/systems/{sid}/subsystems?limit=100"))
    ctrls = items(get_json(f"/systems/{sid}/controlstreams?limit=100"))
    for d in items(get_json(f"/systems/{sid}/datastreams?limit=200")):
        did = d.get("id", "")
        oname = d.get("outputName") or ""
        schema = get_json(f"/datastreams/{did}/schema?obsFormat={q('application/swe+json')}")
        if schema is None:
            types_s, top = "(no swe+json schema)", ""
        else:
            rs = schema.get("recordSchema", {})
            types_s = ",".join(sorted(component_types(rs)))
            top = " ".join(f"{f.get('name')}:{f.get('type')}"
                           for f in (rs.get("fields") or rs.get("field") or []))
        binary = get_json(f"/datastreams/{did}/schema?obsFormat={q('application/swe+binary')}")
        print(f"{sname[:23]:<24} {sid:<13} {did:<13} {oname[:25]:<26} "
              f"{'yes' if binary else 'no':<4} {types_s[:43]:<44} {top[:60]}")
    note = []
    if subs:
        note.append(f"{len(subs)} subsystem(s)")
    if ctrls:
        note.append(f"{len(ctrls)} control stream(s): " +
                    ", ".join(f"{c.get('id')} ({c.get('inputName')})" for c in ctrls))
    if note:
        print(f"{'':<24} {sid:<13} -> " + "; ".join(note))
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# Capture
#
# Fixture selection covers every distinct schema shape the node offers:
#   weather             plain scalar record (Quantity/Count/Text)
#   ais-vessel-location Boolean + Category + Text + Count + Vector + nilValues
#   spectrum-array      two variable-size DataArrays via elementCount href refs
#   video-mjpeg         nested DataArray + BinaryBlock; no swe+json schema (400)
#   gps                 Time + Vector, the shape this app itself writes
#   kraken-settings     nested DataRecord, deepest tree on the node
#   kraken-doa          direction-finding LOB; emits only on detection, so its
#                       binary capture comes from REST rather than the socket
#   choice-ptz-control  control stream whose paramsSchema is a DataChoice
#   lrf-target          a laser range finder's target point: Time + a Vector
#                       defined as FeatureOfInterestLocation, observed from a
#                       phone that the record never names
#   lrf-range           the same range finder's range/azimuth/inclination
#                       record — an azimuth with no location vector, which must
#                       stay a bearing
#
# `capture` takes an optional slug filter — `capture kraken-doa` refreshes one
# fixture folder and leaves the committed rest untouched.
# ─────────────────────────────────────────────────────────────────────────────
do_capture() {
python3 - <<PY
$PY_COMMON
import os

FIXTURES = os.environ["FIXTURE_ROOT"]
ONLY = [s for s in os.environ.get("CAPTURE_ONLY", "").split() if s]

DATASTREAMS = [
    # slug,                 datastream id,  system id
    ("weather",             "02d91178rlfg", "02abbuuhn57g"),
    ("ais-vessel-location", "0c10",         "0c0g"),
    ("spectrum-array",      "0g1g",         "0g0g"),
    ("video-mjpeg",         "02jr71ulsgig", "02luf9f2mgag"),
    ("gps",                 "0k0g",         "0k0g"),
    ("kraken-settings",     "0g0g",         "0g0g"),
    ("kraken-doa",          "0g10",         "0g0g"),
    ("lrf-target",          "03d9tsleg9eg", "02nqpau0r420"),
    ("lrf-range",           "02ne3au3op6g", "02nqpau0r420"),
]

# slug -> extra systems to capture beside the datastream's own, as
# (file prefix, system id). A laser range finder observes a target *from*
# somewhere, and the phone it is carried by is a second system: how the two are
# related — a parent link, a subsystem entry, an identifier in the record, or
# nothing at all — is exactly what the source resolver has to decide, so both
# registrations and both subsystem collections are captured, empty or not.
RELATED_SYSTEMS = {
    "lrf-target": [("source", "02cfdsfiopmg")],
    "lrf-range":  [("source", "02cfdsfiopmg")],
}

# slug -> (system id, control stream id)
CONTROL_STREAMS = [
    ("choice-ptz-control", "02luf9f2mgag", "025svjetu8qg"),
]

def write(slug, name, data):
    d = os.path.join(FIXTURES, slug)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    print(f"    {name} ({len(data)} bytes)")

def write_if_200(slug, name, path, accept=None):
    status, body = request(path, accept=accept)
    if status != 200:
        print(f"    - {name}: HTTP {status} (skipped)")
        return None
    write(slug, name, body)
    return body

def capture_binary(slug, did):
    """Three binary observation messages, plus an index of their byte lengths.

    Tried over the WebSocket stream first, since that is where a live datastream
    delivers frame-aligned messages. An archive-only datastream produces nothing
    there, so the fallback reads the same records over REST and recovers each
    message's length by differencing successive limit=N responses — the REST
    body concatenates records with no delimiter, and the lengths are what let a
    test split them again.
    """
    lengths, source = ws_capture(did, count=3, timeout=30), "websocket"
    if not lengths:
        source = "rest"
        blobs = []
        prev = b""
        for n in (1, 2, 3):
            status, body = request(
                f"/datastreams/{did}/observations?f={q('application/swe+binary')}&limit={n}")
            if status != 200 or not body:
                break
            blobs.append(body[len(prev):])
            prev = body
        lengths = [b for b in blobs if b]

    if not lengths:
        print("    - obs-binary.bin: no binary observations available")
        return

    write(slug, "obs-binary.bin", b"".join(lengths))
    index = {
        "source": source,
        "messageLengths": [len(b) for b in lengths],
        "note": ("Captured from the live WebSocket stream; each length is one "
                 "WebSocket message." if source == "websocket" else
                 "Captured from REST (GET observations?f=application/swe+binary) "
                 "because the WebSocket stream produced nothing within the "
                 "timeout — an archive-only datastream. Lengths were recovered "
                 "by differencing successive limit=N responses."),
    }
    write(slug, "obs-binary.index.json", json.dumps(index, indent=2) + "\n")

def ws_capture(did, count=3, timeout=30):
    """Minimal RFC 6455 client over a raw socket — standard library only.

    Returns a list of message payloads, or [] if the stream is silent. Only the
    client half of the protocol is implemented: a masked close is never needed
    because the socket is dropped, and server frames are never masked.
    """
    import os as _os, socket, struct, time, urllib.parse as _up

    u = _up.urlparse(BASE)
    host, port = u.hostname, u.port or (443 if u.scheme == "https" else 80)
    path = f"{u.path}/datastreams/{did}/observations?f={q('application/swe+binary')}"
    key = base64.b64encode(_os.urandom(16)).decode()

    handshake = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
    )
    if _AUTH:
        handshake += f"Authorization: {_AUTH}\r\n"
    handshake += "\r\n"

    try:
        sock = socket.create_connection((host, port), timeout=10)
        if u.scheme == "https":
            import ssl
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        sock.sendall(handshake.encode())

        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                return []
            buf += chunk
        head, buf = buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            return []

        messages, deadline = [], time.time() + timeout
        sock.settimeout(2)
        while len(messages) < count and time.time() < deadline:
            try:
                while True:
                    # Frame header: need 2 bytes, then the extended length.
                    while len(buf) < 2:
                        buf += sock.recv(65536)
                    b1, b2 = buf[0], buf[1]
                    opcode, plen = b1 & 0x0F, b2 & 0x7F
                    offset = 2
                    if plen == 126:
                        while len(buf) < 4:
                            buf += sock.recv(65536)
                        plen = struct.unpack(">H", buf[2:4])[0]
                        offset = 4
                    elif plen == 127:
                        while len(buf) < 10:
                            buf += sock.recv(65536)
                        plen = struct.unpack(">Q", buf[2:10])[0]
                        offset = 10
                    while len(buf) < offset + plen:
                        buf += sock.recv(65536)
                    payload, buf = buf[offset:offset + plen], buf[offset + plen:]
                    if opcode == 0x8:      # close
                        return messages
                    if opcode in (0x1, 0x2) and payload:
                        messages.append(payload)
                        break
            except socket.timeout:
                continue
            except Exception:
                break
        sock.close()
        return messages
    except Exception:
        return []

# ── datastream fixtures ──────────────────────────────────────────────────────
for slug, did, sid in DATASTREAMS:
    if ONLY and slug not in ONLY:
        continue
    print(f"[{slug}] datastream {did} (system {sid})")
    write_if_200(slug, "datastream.json", f"/datastreams/{did}")
    write_if_200(slug, "schema-json.json",
                 f"/datastreams/{did}/schema?obsFormat={q('application/swe+json')}")
    write_if_200(slug, "schema-binary.json",
                 f"/datastreams/{did}/schema?obsFormat={q('application/swe+binary')}")
    write_if_200(slug, "obs-json.json",
                 f"/datastreams/{did}/observations?f={q('application/swe+json')}&limit=3")
    write_if_200(slug, "obs-omjson.json",
                 f"/datastreams/{did}/observations?f={q('application/om+json')}&limit=3")
    capture_binary(slug, did)
    write_if_200(slug, "system.json", f"/systems/{sid}")
    subs = get_json(f"/systems/{sid}/subsystems?limit=100")
    # Normally written only when non-empty. For a slug with related systems the
    # empty collection is the finding — "the LRF is not a subsystem of the
    # phone" is a fact a test asserts — so it is written either way.
    if subs is not None and (items(subs) or slug in RELATED_SYSTEMS):
        write(slug, "subsystems.json", json.dumps(subs, indent=2) + "\n")

    for prefix, related in RELATED_SYSTEMS.get(slug, []):
        write_if_200(slug, f"{prefix}-system.json", f"/systems/{related}")
        related_subs = get_json(f"/systems/{related}/subsystems?limit=100")
        if related_subs is not None:
            write(slug, f"{prefix}-subsystems.json",
                  json.dumps(related_subs, indent=2) + "\n")

# ── control stream fixtures (Pass 4 seed; no command support in this pass) ────
for slug, sid, csid in CONTROL_STREAMS:
    if ONLY and slug not in ONLY:
        continue
    print(f"[{slug}] control stream {csid} (system {sid})")
    write_if_200(slug, "controlstreams.json", f"/systems/{sid}/controlstreams?limit=100")
    write_if_200(slug, "control-schema.json",
                 f"/controlstreams/{csid}/schema?commandFormat={q('application/swe+json')}")
    write_if_200(slug, "system.json", f"/systems/{sid}")
PY
}

case "$MODE" in
  survey)  do_survey ;;
  capture)
    export CAPTURE_ONLY="${*:2}"
    do_capture
    echo
    echo "Syncing Xcode project"
    # New fixture files must be listed in the test target's membership
    # exceptions or the synchronized folder group flattens them into the
    # bundle root; see the script's own docstring.
    python3 "$REPO_ROOT/scripts/sync-fixture-membership.py"
    ;;
  sync)    python3 "$REPO_ROOT/scripts/sync-fixture-membership.py" ;;
  *) echo "usage: $0 [survey|capture [slug...]|sync]" >&2; exit 2 ;;
esac
