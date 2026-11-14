#!/usr/bin/env bash
# KimAI v0.2 integration tests in an isolated environment.
# The real user session is never touched: HOME, XDG_DATA_HOME and
# XDG_RUNTIME_DIR are all redirected to a temporary directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIMAI="$HERE/../kimai"

if [[ ! -x "$KIMAI" ]]; then
  echo "FAIL: $KIMAI is not executable" >&2
  exit 1
fi

REAL_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
OWN_ROOT=0

if [[ -n "${KIMAI_TEST_ROOT:-}" ]]; then
  ROOT="$KIMAI_TEST_ROOT"
  export HOME="$ROOT/home"
  export XDG_DATA_HOME="$ROOT/data"
  export XDG_RUNTIME_DIR="$ROOT/run"
elif [[ -n "${HOME:-}" && -n "${XDG_DATA_HOME:-}" && -n "${XDG_RUNTIME_DIR:-}" \
        && "$HOME" != "$REAL_HOME" ]]; then
  # Respect an isolated environment supplied by the caller.
  ROOT="$(dirname "$XDG_RUNTIME_DIR")"
else
  # Safe default: never touch the real user session.
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kimai-test.XXXXXX")"
  OWN_ROOT=1
  export HOME="$ROOT/home"
  export XDG_DATA_HOME="$ROOT/data"
  export XDG_RUNTIME_DIR="$ROOT/run"
fi

mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
unset XDG_CONFIG_HOME 2>/dev/null || true

# Desktop notifications are verified separately; keep the test silent.
export KIMAI_NOTIFY=0

SOCK="$XDG_RUNTIME_DIR/kimai.sock"
LOG="$ROOT/daemon.log"
DATA="$XDG_DATA_HOME/kimai/approvals.jsonl"
EVENTS="$XDG_DATA_HOME/kimai/events.jsonl"
PID=""

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    "$KIMAI" stop >/dev/null 2>&1 || true
    sleep 0.2
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [[ "$OWN_ROOT" -eq 1 ]]; then
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

echo "Test directory: $ROOT"

# 1. The daemon starts and the basic status is correct.
"$KIMAI" start >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 50); do
  [[ -S "$SOCK" ]] && break
  sleep 0.1
done
if [[ ! -S "$SOCK" ]]; then
  cat "$LOG" >&2 || true
  fail "the socket did not appear"
fi
[[ "$(stat -c '%a' "$SOCK")" == "600" ]] || fail "socket mode is not 0600"
pass "daemon started, socket mode 0600 at $SOCK"

STATUS_JSON="$("$KIMAI" status)"
printf '%s\n' "$STATUS_JSON"
STATUS_JSON="$STATUS_JSON" python3 - <<'PY'
import json
import os

status = json.loads(os.environ["STATUS_JSON"])
assert status["version"] == "0.2.0", status
assert status["ai_enabled"] is False, status
assert status["pending_approvals"] == 0, status
assert status["events_received"] == 0, status
assert status["notify"] is False, status
assert status["socket"].endswith("kimai.sock"), status
assert status["uptime_s"] >= 0, status
PY
pass "status reports version, ai_enabled:false, socket, 0 approvals, 0 events"

PING_JSON="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
sock.sendall((json.dumps({"id": "ping-1", "op": "ping", "args": {}}) + "\n").encode())
line = sock.makefile("rb").readline()
sock.close()
print(line.decode().strip())
PY
)"
printf '%s\n' "$PING_JSON"
PING_JSON="$PING_JSON" python3 - <<'PY'
import json
import os

response = json.loads(os.environ["PING_JSON"])
assert response["id"] == "ping-1", response
assert response["ok"] is True, response
assert response["result"] == {"pong": True, "version": "0.2.0"}, response
PY
pass "op ping"

# 2. ask without configuration must stay honest.
if ASK_OUT="$("$KIMAI" ask "what is this" 2>&1)"; then
  fail "ask should have exited non-zero"
fi
printf '%s\n' "$ASK_OUT"
[[ "$ASK_OUT" == *"AI is not configured"* ]] || fail "the ask message is wrong"
pass "ask returns AI is not configured"

# 3. An empty queue must be explicit and exit 0.
LIST_OUT="$("$KIMAI" approve list)"
printf '%s\n' "$LIST_OUT"
[[ "$LIST_OUT" == *"No approval requests."* ]] || fail "the empty list message is unclear"
pass "approve list is empty"

# 4. A raw client submits an approve.request.
REQUEST_ID="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
request = {
    "id": "raw-test-1",
    "op": "approve.request",
    "args": {
        "tool": "KimScanning",
        "action": "scan-directory",
        "args": {"target": "/tmp", "depth": 2},
        "risk": "medium",
        "reason": "integration test",
    },
}
sock.sendall((json.dumps(request) + "\n").encode())
line = sock.makefile("rb").readline()
sock.close()
response = json.loads(line)
assert response["id"] == "raw-test-1", response
assert response["ok"] is True, response
print(response["result"]["request_id"])
PY
)"
[[ "$REQUEST_ID" == req-* ]] || fail "request_id is invalid"
pass "raw approve.request returned $REQUEST_ID"

LIST_OUT="$("$KIMAI" approve list)"
printf '%s\n' "$LIST_OUT"
[[ "$LIST_OUT" == *"$REQUEST_ID"* ]] || fail "approve list does not show the request"
pass "approve list shows the new request"

"$KIMAI" approve yes "$REQUEST_ID" --note "test"
pass "approve yes records the decision"

# 5. The record file must contain two append-only rows.
[[ -f "$DATA" ]] || fail "approvals.jsonl does not exist"
[[ "$(wc -l <"$DATA")" -eq 2 ]] || fail "the record file does not have 2 rows"
python3 - "$DATA" "$REQUEST_ID" <<'PY'
import json
import sys

path, request_id = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    rows = [json.loads(line) for line in handle if line.strip()]
assert len(rows) == 2, rows
for row in rows:
    assert row["request_id"] == request_id, row
    for key in ("ts", "tool", "action", "args", "risk", "reason", "decision", "note"):
        assert key in row, (key, row)
assert rows[0]["decision"] is None, rows[0]
assert rows[0]["note"] == "", rows[0]
assert rows[1]["decision"] == "approve", rows[1]
assert rows[1]["note"] == "test", rows[1]
assert rows[1]["args"] == {"target": "/tmp", "depth": 2}, rows[1]
PY
cat "$DATA"
pass "approvals.jsonl holds the request row and the decision row"

# 6. Event sink: a finding from another tool is recorded append-only.
EVENT_JSON="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
request = {
    "id": "event-1",
    "op": "event",
    "args": {
        "source": "kimlogpipe",
        "kind": "ssh_bruteforce",
        "severity": "high",
        "summary": "6 failed SSH authentications from 10.0.2.2 in 300s",
        "data": {"src_ip": "10.0.2.2", "count": 6},
    },
}
sock.sendall((json.dumps(request) + "\n").encode())
line = sock.makefile("rb").readline()
sock.close()
print(line.decode().strip())
PY
)"
printf '%s\n' "$EVENT_JSON"
EVENT_ID="$(EVENT_JSON="$EVENT_JSON" python3 - <<'PY'
import json
import os

response = json.loads(os.environ["EVENT_JSON"])
assert response["ok"] is True, response
assert response["result"]["event_id"].startswith("ev-"), response
assert response["result"]["notified"] is False, response
print(response["result"]["event_id"])
PY
)"
pass "op event returned $EVENT_ID (notification suppressed by KIMAI_NOTIFY=0)"

[[ -f "$EVENTS" ]] || fail "events.jsonl does not exist"
python3 - "$EVENTS" "$EVENT_ID" <<'PY'
import json
import sys

path, event_id = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    rows = [json.loads(line) for line in handle if line.strip()]
assert len(rows) == 1, rows
row = rows[0]
assert row["event_id"] == event_id, row
assert row["source"] == "kimlogpipe", row
assert row["kind"] == "ssh_bruteforce", row
assert row["severity"] == "high", row
assert row["data"] == {"src_ip": "10.0.2.2", "count": 6}, row
assert row["notified"] is False, row
assert row["ts"].endswith("Z"), row
PY
pass "events.jsonl holds the event with its original data"

STATUS_JSON="$("$KIMAI" status)"
STATUS_JSON="$STATUS_JSON" python3 - <<'PY'
import json
import os

status = json.loads(os.environ["STATUS_JSON"])
assert status["events_received"] == 1, status
PY
pass "status counts the received events"

EVENTS_OUT="$("$KIMAI" events --limit 5)"
printf '%s\n' "$EVENTS_OUT"
[[ "$EVENTS_OUT" == *"ssh_bruteforce"* ]] || fail "kimai events does not show the event"
pass "kimai events lists the event"

# 7. An invalid event must be rejected, not stored.
BAD_JSON="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
sock.sendall(
    (json.dumps({"id": "bad-1", "op": "event", "args": {"source": "x"}}) + "\n").encode()
)
line = sock.makefile("rb").readline()
sock.close()
print(line.decode().strip())
PY
)"
printf '%s\n' "$BAD_JSON"
BAD_JSON="$BAD_JSON" python3 - <<'PY'
import json
import os

response = json.loads(os.environ["BAD_JSON"])
assert response["ok"] is False, response
assert "kind" in response["error"], response
PY
[[ "$(wc -l <"$EVENTS")" -eq 1 ]] || fail "an invalid event was stored"
pass "an invalid event is rejected and not stored"

# 8. An unknown op.
UNKNOWN_JSON="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
sock.sendall((json.dumps({"id": "x", "op": "no.op", "args": {}}) + "\n").encode())
line = sock.makefile("rb").readline()
sock.close()
print(line.decode().strip())
PY
)"
printf '%s\n' "$UNKNOWN_JSON"
UNKNOWN_JSON="$UNKNOWN_JSON" python3 - <<'PY'
import json
import os

response = json.loads(os.environ["UNKNOWN_JSON"])
assert response["ok"] is False, response
assert "Unknown op" in response["error"], response
PY
pass "an unknown op is rejected"

# 9. The daemon file contains no HTTP client.
HTTP_COUNT="$(grep -c "http" "$KIMAI" || true)"
[[ "$HTTP_COUNT" -eq 0 ]] || fail "the daemon file contains 'http' ($HTTP_COUNT)"
pass "grep -c http kimai/kimai = 0"

# 10. stop removes the socket; status afterwards fails with a clear message.
"$KIMAI" stop
[[ ! -e "$SOCK" ]] || fail "the socket still exists after stop"
pass "stop removes the socket"
sleep 0.2
PID=""

if STOP_OUT="$("$KIMAI" status 2>&1)"; then
  fail "status after stop should have exited non-zero"
fi
printf '%s\n' "$STOP_OUT"
[[ "$STOP_OUT" == *"KimAI is not running"* ]] || fail "the not-running message is unclear"
pass "status after stop reports KimAI is not running"

echo "ALL TESTS PASSED"
