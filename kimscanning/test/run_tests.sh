#!/usr/bin/env bash
# Ujian KimScanning v1.
# Semua ujian menggunakan HOME dan XDG_DATA_HOME sementara.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
KIMSCAN="$REPO/kimscanning/kimscan"

PASS=0
FAIL=0
RC=0
LAST_OUT=""

ok()   { PASS=$((PASS + 1)); echo "  OK    - $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  GAGAL - $*"; }
section() { echo; echo "== $* =="; }

run() {
    LAST_OUT="$TMP/logs/last.out"
    "$@" >"$LAST_OUT" 2>&1
    RC=$?
}

assert_rc() {
    local label=$1 want=$2
    if [ "$RC" -eq "$want" ]; then
        ok "$label (exit $RC)"
    else
        bad "$label: exit $RC, mahu $want"
        sed -n '1,40p' "$LAST_OUT" 2>/dev/null | sed 's/^/      /'
    fi
}

assert_file() {
    local label=$1 path=$2
    if [ -f "$path" ]; then ok "$label"; else bad "$label: tiada $path"; fi
}

assert_contains() {
    local label=$1 needle=$2
    if grep -Fq -- "$needle" "$LAST_OUT"; then
        ok "$label"
    else
        bad "$label: tidak jumpa '$needle'"
        sed -n '1,40p' "$LAST_OUT" 2>/dev/null | sed 's/^/      /'
    fi
}

last_id() {
    ls -1 "$XDG_DATA_HOME/kimscanning/sessions" 2>/dev/null | sort | tail -n1
}

session_file() {
    echo "$XDG_DATA_HOME/kimscanning/sessions/$1/session.json"
}

session_count() {
    ls -1 "$XDG_DATA_HOME/kimscanning/sessions" 2>/dev/null | wc -l | tr -d ' '
}

if [ ! -x "$KIMSCAN" ]; then
    echo "RALAT: $KIMSCAN tidak boleh dijalankan." >&2
    exit 1
fi

REAL_HOME=${HOME:-}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kimscan-uji.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/logs" "$TMP/cwd" "$TMP/uji-bersih" "$TMP/uji-bocor"
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$XDG_DATA_HOME"

# Alat mudah alih untuk ujian ini (jika ada), tanpa mengubah pemasangan sistem.
if [ -d /tmp/opencode/bin ]; then
    PATH="/tmp/opencode/bin:$PATH"
fi
export PATH
export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0

# Cache trivy boleh dikongsi melalui KIMSCAN_TRIVY_CACHE untuk ujian yang lebih
# pantas; jika tidak, cache sementara digunakan dan dibuang selepas ujian.
export TRIVY_CACHE_DIR="${KIMSCAN_TRIVY_CACHE:-$TMP/trivy-cache}"

cd "$TMP/cwd"

section "Semakan sintaks"
if PYTHONPYCACHEPREFIX="$TMP/pycache" python3 -m py_compile "$KIMSCAN"; then
    ok "python3 -m py_compile kimscan"
else
    bad "python3 -m py_compile kimscan"
fi
if bash -n "$SCRIPT_DIR/run_tests.sh"; then
    ok "bash -n run_tests.sh"
else
    bad "bash -n run_tests.sh"
fi

section "1. doctor"
run "$KIMSCAN" doctor
assert_rc "doctor" 0
sed -n '1,12p' "$LAST_OUT" | sed 's/^/      /'
for t in gitleaks semgrep trivy nuclei nikto nmap ssh-audit; do
    line=$(grep -E "^$t[[:space:]]" "$LAST_OUT" || true)
    if command -v "$t" >/dev/null 2>&1; then
        if printf '%s\n' "$line" | grep -Fq "tersedia"; then
            ok "doctor: $t tersedia"
        else
            bad "doctor: $t ada pada PATH tetapi tidak dilaporkan tersedia"
        fi
    else
        if printf '%s\n' "$line" | grep -Fq "tiada"; then
            ok "doctor: $t tiada"
        else
            bad "doctor: $t tiada pada PATH tetapi tidak dilaporkan tiada"
        fi
    fi
done

HAVE_REPO_TOOLS=1
for t in gitleaks semgrep trivy; do
    command -v "$t" >/dev/null 2>&1 || HAVE_REPO_TOOLS=0
done

if [ "$HAVE_REPO_TOOLS" -ne 1 ]; then
    section "Ujian imbasan repo dilangkau"
    echo "  SKIP  - gitleaks/semgrep/trivy tidak lengkap pada PATH." >&2
    section "Ringkasan"
    echo "  Lulus: $PASS  Gagal: $FAIL  (ujian repo dilangkau)"
    exit 0
fi

# Folder bersih.
cat > "$TMP/uji-bersih/hello.py" <<'PY'
def salam(nama):
    return f"Halo, {nama}!"
PY
printf '# Uji bersih\n\nFolder contoh yang selamat.\n' > "$TMP/uji-bersih/README.md"

# Folder bocor: kunci AWS rawak. Gitleaks hanya menerima A-Z2-7 dalam 16 aksara
# terakhir, jadi jana daripada set itu (bukan AKIAIOSFODNN7EXAMPLE).
AWS_KEY="AKIA$(tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"
printf 'AWS_ACCESS_KEY_ID=%s\n' "$AWS_KEY" > "$TMP/uji-bocor/config.env"

section "2. Imbasan repo bersih"
run "$KIMSCAN" repo "$TMP/uji-bersih"
assert_rc "repo bersih" 0
assert_contains "verdict LULUS" "|   LULUS"
CLEAN_ID=$(last_id)
assert_file "session.json wujud" "$(session_file "$CLEAN_ID")"
assert_file "report.md wujud" "$XDG_DATA_HOME/kimscanning/sessions/$CLEAN_ID/report.md"
if [ -d "$XDG_DATA_HOME/kimscanning/sessions/$CLEAN_ID/raw" ]; then
    ok "raw/ wujud"
else
    bad "raw/ tiada"
fi
if python3 - "$(session_file "$CLEAN_ID")" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "LULUS", s["verdict"]
assert s["counts"] == {"critical": 0, "high": 0, "medium": 0, "low": 0}
PY
then
    ok "schema verdict/counts bersih"
else
    bad "schema verdict/counts bersih"
fi

section "2b. NDJSON --json"
run "$KIMSCAN" repo "$TMP/uji-bersih" --json
assert_rc "repo bersih --json" 0
assert_contains "NDJSON start" '"phase":"start"'
assert_contains "NDJSON scanner" '"phase":"scanner"'
assert_contains "NDJSON done" '"phase":"done"'
if python3 - "$LAST_OUT" <<'PY'
import json, sys
lines = [json.loads(x) for x in open(sys.argv[1]) if x.strip()]
phases = [x.get("phase") for x in lines]
assert phases[0] == "start", phases
assert "scanner" in phases, phases
assert phases[-1] == "done", phases
PY
then
    ok "semua baris stdout ialah JSON yang sah"
else
    bad "NDJSON tidak sah"
fi

section "3. Imbasan repo bocor (kali pertama)"
run "$KIMSCAN" repo "$TMP/uji-bocor"
assert_rc "repo bocor" 3
assert_contains "verdict TIDAK LULUS" "|   TIDAK LULUS"
ID1=$(last_id)
S1=$(session_file "$ID1")
assert_file "session.json bocor" "$S1"
if python3 - "$S1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "TIDAK LULUS", s["verdict"]
assert s["counts"]["high"] >= 1, s["counts"]
f = [x for x in s["findings"] if x["tool"] == "gitleaks" and x["rule"] == "aws-access-token"]
assert f, [x["rule"] for x in s["findings"]]
assert f[0]["explanation"], f[0]
assert f[0]["explanation"]["apa"], f[0]
assert f[0]["status"] == "baru", f[0]["status"]
PY
then
    ok "dapatan AWS ada penjelasan BM dan status baru"
else
    bad "dapatan AWS tiada penjelasan/status"
fi

FP=$(python3 - "$S1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for f in s["findings"]:
    if f["tool"] == "gitleaks" and f["rule"] == "aws-access-token":
        print(f["fp"])
        break
PY
)
if [ -n "$FP" ]; then ok "fp AWS: $FP"; else bad "fp AWS tidak dijumpai"; fi

section "4. Imbasan kedua — status dikekalkan"
run "$KIMSCAN" repo "$TMP/uji-bocor"
assert_rc "repo bocor kali kedua" 3
ID2=$(last_id)
S2=$(session_file "$ID2")
if python3 - "$S1" "$S2" "$FP" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
fp = sys.argv[3]
fa = next(x for x in a["findings"] if x["fp"] == fp)
fb = next(x for x in b["findings"] if x["fp"] == fp)
assert fa["status"] == fb["status"] == "baru", (fa["status"], fb["status"])
assert fa["first_seen"] == fb["first_seen"], (fa["first_seen"], fb["first_seen"])
assert fb["last_seen"] >= fa["last_seen"], (fa["last_seen"], fb["last_seen"])
PY
then
    ok "status baru dikekalkan; first_seen sama; last_seen dikemas kini"
else
    bad "status carry-over gagal"
fi

section "5. status diterima + imbasan ketiga"
run "$KIMSCAN" status "$ID1" "$FP" diterima
assert_rc "kimscan status" 0
run "$KIMSCAN" repo "$TMP/uji-bocor"
assert_rc "repo bocor kali ketiga" 3
ID3=$(last_id)
S3=$(session_file "$ID3")
if python3 - "$S1" "$S2" "$S3" "$FP" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
c = json.load(open(sys.argv[3]))
fp = sys.argv[4]
fa = next(x for x in a["findings"] if x["fp"] == fp)
fb = next(x for x in b["findings"] if x["fp"] == fp)
fc = next(x for x in c["findings"] if x["fp"] == fp)
assert fa["first_seen"] == fc["first_seen"], (fa["first_seen"], fc["first_seen"])
assert fb["status"] == "baru", fb["status"]
assert fc["status"] == "diterima", fc["status"]
PY
then
    ok "status diterima kekal pada imbasan ketiga walaupun sesi kedua baru"
else
    bad "status diterima tidak dikekalkan"
fi

section "6. web tanpa --authorized"
BEFORE=$(session_count)
run "$KIMSCAN" web http://127.0.0.1
assert_rc "web tanpa kebenaran" 1
assert_contains "mesej kebenaran BM" "authorized"
AFTER=$(session_count)
if [ "$BEFORE" -eq "$AFTER" ]; then
    ok "tiada sesi dicipta untuk imbasan yang ditolak"
else
    bad "sesi dicipta walaupun imbasan ditolak ($BEFORE -> $AFTER)"
fi

section "7. rules --missing"
run "$KIMSCAN" rules --missing
assert_rc "rules --missing" 0
sed -n '1,16p' "$LAST_OUT" | sed 's/^/      /'
if grep -Fq "Rule id tiada penjelasan: 0" "$LAST_OUT"; then
    ok "tiada rule id hilang (dilaporkan jujur)"
elif grep -Eq '^  [a-zA-Z0-9._-]+/.*\(' "$LAST_OUT"; then
    ok "sekurang-kurangnya satu rule id tiada penjelasan disenaraikan"
else
    bad "output rules --missing tidak dijangka"
fi

section "8. Tiada tulisan di luar kawasan"
if [ -z "$(find "$TMP/cwd" -mindepth 1 -print -quit)" ]; then
    ok "direktori kerja ujian kekal kosong"
else
    bad "ada fail dicipta dalam direktori kerja ujian"
    find "$TMP/cwd" -mindepth 1 -maxdepth 2 | sed 's/^/      /'
fi
DATA_ENTRIES=$(find "$XDG_DATA_HOME" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')
if [ "$DATA_ENTRIES" = "kimscanning " ]; then
    ok "XDG_DATA_HOME hanya mengandungi kimscanning"
else
    bad "XDG_DATA_HOME mengandungi entri lain: $DATA_ENTRIES"
fi
if git -C "$REPO" diff --quiet -- gate/gate.py dotfiles install.sh; then
    ok "gate/gate.py, dotfiles/** dan install.sh tidak diubah"
else
    bad "fail terlarang diubah"
fi
if [ -e "$REPO/gate-out" ]; then
    bad "gate-out dicipta dalam repo"
else
    ok "tiada gate-out dalam repo"
fi

section "Ringkasan"
echo "  Lulus: $PASS  Gagal: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
