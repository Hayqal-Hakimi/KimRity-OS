#!/usr/bin/env bash
# Ujian integrasi KimAI v1 dalam persekitaran terasing.
# Tidak menyentuh sesi pengguna sebenar: HOME, XDG_DATA_HOME dan
# XDG_RUNTIME_DIR semuanya dialihkan ke direktori sementara.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIMAI="$HERE/../kimai"

if [[ ! -x "$KIMAI" ]]; then
  echo "GAGAL: $KIMAI bukan fail boleh laku" >&2
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
  # Hormati persekitaran terasing yang diberikan oleh pemanggil.
  ROOT="$(dirname "$XDG_RUNTIME_DIR")"
else
  # Lalai selamat: jangan sentuh sesi pengguna sebenar.
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kimai-test.XXXXXX")"
  OWN_ROOT=1
  export HOME="$ROOT/home"
  export XDG_DATA_HOME="$ROOT/data"
  export XDG_RUNTIME_DIR="$ROOT/run"
fi

mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
unset XDG_CONFIG_HOME 2>/dev/null || true

SOCK="$XDG_RUNTIME_DIR/kimai.sock"
LOG="$ROOT/daemon.log"
DATA="$XDG_DATA_HOME/kimai/approvals.jsonl"
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

pass() { printf 'LULUS: %s\n' "$1"; }
fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

echo "Direktori ujian: $ROOT"

# 1. Daemon bermula dan status asas betul.
"$KIMAI" start >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 50); do
  [[ -S "$SOCK" ]] && break
  sleep 0.1
done
if [[ ! -S "$SOCK" ]]; then
  cat "$LOG" >&2 || true
  fail "socket tidak muncul"
fi
[[ "$(stat -c '%a' "$SOCK")" == "600" ]] || fail "mod socket bukan 0600"
pass "daemon bermula, socket mod 0600 di $SOCK"

STATUS_JSON="$("$KIMAI" status)"
printf '%s\n' "$STATUS_JSON"
STATUS_JSON="$STATUS_JSON" python3 - <<'PY'
import json
import os

status = json.loads(os.environ["STATUS_JSON"])
assert status["version"] == "0.1.0", status
assert status["ai_enabled"] is False, status
assert status["pending_approvals"] == 0, status
assert status["socket"].endswith("kimai.sock"), status
assert status["uptime_s"] >= 0, status
PY
pass "status memaparkan versi, ai_enabled:false, socket dan 0 kelulusan"

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
assert response["result"] == {"pong": True, "version": "0.1.0"}, response
PY
pass "op ping"

# 2. ask tanpa konfigurasi mesti jujur.
if ASK_OUT="$("$KIMAI" ask "apa ini" 2>&1)"; then
  fail "ask sepatutnya keluar bukan sifar"
fi
printf '%s\n' "$ASK_OUT"
[[ "$ASK_OUT" == *"AI belum dikonfigurasi"* ]] || fail "mesej ask tidak tepat"
pass "ask memulangkan AI belum dikonfigurasi"

# 3. Senarai kosong mesti jelas dan keluar 0.
LIST_OUT="$("$KIMAI" approve list)"
printf '%s\n' "$LIST_OUT"
[[ "$LIST_OUT" == *"Tiada permintaan kelulusan."* ]] || fail "mesej senarai kosong tidak jelas"
pass "approve list kosong"

# 4. Klien mentah menghantar approve.request.
REQUEST_ID="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
request = {
    "id": "ujian-mentah-1",
    "op": "approve.request",
    "args": {
        "tool": "KimScanning",
        "action": "imbas-direktori",
        "args": {"sasaran": "/tmp", "kedalaman": 2},
        "risk": "sederhana",
        "reason": "ujian integrasi",
    },
}
sock.sendall((json.dumps(request) + "\n").encode())
line = sock.makefile("rb").readline()
sock.close()
response = json.loads(line)
assert response["id"] == "ujian-mentah-1", response
assert response["ok"] is True, response
print(response["result"]["request_id"])
PY
)"
[[ "$REQUEST_ID" == req-* ]] || fail "request_id tidak sah"
pass "approve.request mentah memulangkan $REQUEST_ID"

LIST_OUT="$("$KIMAI" approve list)"
printf '%s\n' "$LIST_OUT"
[[ "$LIST_OUT" == *"$REQUEST_ID"* ]] || fail "approve list tidak menunjukkan permintaan"
pass "approve list menunjukkan permintaan baharu"

"$KIMAI" approve yes "$REQUEST_ID" --note "uji"
pass "approve yes merekodkan keputusan"

# 5. Fail rekod mesti mempunyai dua baris tambah-sahaja.
[[ -f "$DATA" ]] || fail "approvals.jsonl tidak wujud"
[[ "$(wc -l <"$DATA")" -eq 2 ]] || fail "bilangan baris rekod bukan 2"
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
assert rows[1]["decision"] == "lulus", rows[1]
assert rows[1]["note"] == "uji", rows[1]
assert rows[1]["args"] == {"sasaran": "/tmp", "kedalaman": 2}, rows[1]
PY
cat "$DATA"
pass "approvals.jsonl mengandungi baris permintaan dan keputusan"

# 6. Op tidak dikenali.
UNKNOWN_JSON="$(python3 - "$SOCK" <<'PY'
import json
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(sys.argv[1])
sock.sendall((json.dumps({"id": "x", "op": "tiada.op", "args": {}}) + "\n").encode())
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
assert "tidak dikenali" in response["error"], response
PY
pass "op tidak dikenali ditolak"

# 7. Tiada klien HTTP dalam fail daemon.
HTTP_COUNT="$(grep -c "http" "$KIMAI" || true)"
[[ "$HTTP_COUNT" -eq 0 ]] || fail "fail daemon mengandungi 'http' ($HTTP_COUNT)"
pass "grep -c http kimai/kimai = 0"

# 8. stop membuang socket; status selepas itu gagal dengan mesej jelas.
"$KIMAI" stop
[[ ! -e "$SOCK" ]] || fail "socket masih wujud selepas stop"
pass "stop membuang socket"
sleep 0.2
PID=""

if STOP_OUT="$("$KIMAI" status 2>&1)"; then
  fail "status selepas stop sepatutnya keluar bukan sifar"
fi
printf '%s\n' "$STOP_OUT"
[[ "$STOP_OUT" == *"KimAI tidak berjalan"* ]] || fail "mesej tidak berjalan tidak jelas"
pass "status selepas stop memaparkan KimAI tidak berjalan"

echo "SEMUA UJIAN LULUS"
