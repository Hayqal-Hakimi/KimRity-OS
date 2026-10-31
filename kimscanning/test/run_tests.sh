#!/usr/bin/env bash
# KimScanning v1 tests.
# All tests use a temp HOME and XDG_DATA_HOME.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
KIMSCAN="$REPO/kimscanning/kimscan"

PASS=0
FAIL=0
RC=0
LAST_OUT=""

ok()   { PASS=$((PASS + 1)); echo "  OK    - $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  - $*"; }
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
        bad "$label: exit $RC, want $want"
        sed -n '1,40p' "$LAST_OUT" 2>/dev/null | sed 's/^/      /'
    fi
}

assert_file() {
    local label=$1 path=$2
    if [ -f "$path" ]; then ok "$label"; else bad "$label: missing $path"; fi
}

assert_contains() {
    local label=$1 needle=$2
    if grep -Fq -- "$needle" "$LAST_OUT"; then
        ok "$label"
    else
        bad "$label: did not find '$needle'"
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
    echo "ERROR: $KIMSCAN is not executable." >&2
    exit 1
fi

REAL_HOME=${HOME:-}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kimscan-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/logs" "$TMP/cwd" "$TMP/test-clean" "$TMP/test-leak"
export HOME="$TMP/home"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$XDG_DATA_HOME"

# Portable tools for this test (if any), without touching the system install.
if [ -d /tmp/opencode/bin ]; then
    PATH="/tmp/opencode/bin:$PATH"
fi
export PATH
export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0

# The trivy cache can be shared via KIMSCAN_TRIVY_CACHE for faster tests;
# otherwise a temp cache is used and dropped after the tests.
export TRIVY_CACHE_DIR="${KIMSCAN_TRIVY_CACHE:-$TMP/trivy-cache}"

cd "$TMP/cwd"

section "Syntax checks"
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
        if printf '%s\n' "$line" | grep -Fq "available"; then
            ok "doctor: $t available"
        else
            bad "doctor: $t on PATH but not reported available"
        fi
    else
        if printf '%s\n' "$line" | grep -Fq "available: no"; then
            ok "doctor: $t absent"
        else
            bad "doctor: $t not on PATH but not reported absent"
        fi
    fi
done

HAVE_REPO_TOOLS=1
for t in gitleaks semgrep trivy; do
    command -v "$t" >/dev/null 2>&1 || HAVE_REPO_TOOLS=0
done

if [ "$HAVE_REPO_TOOLS" -ne 1 ]; then
    section "Repo scan tests skipped"
    echo "  SKIP  - gitleaks/semgrep/trivy incomplete on PATH." >&2
    section "Summary"
    echo "  Pass: $PASS  Fail: $FAIL  (repo tests skipped)"
    exit 0
fi

# Clean folder.
cat > "$TMP/test-clean/hello.py" <<'PY'
def greet(name):
    return f"Hello, {name}!"
PY
printf '# Clean test\n\nA safe example folder.\n' > "$TMP/test-clean/README.md"

# Leaking folder: random AWS key. Gitleaks only accepts A-Z2-7 in the last
# 16 chars, so generate from that set (not AKIAIOSFODNN7EXAMPLE).
AWS_KEY="AKIA$(tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"
printf 'AWS_ACCESS_KEY_ID=%s\n' "$AWS_KEY" > "$TMP/test-leak/config.env"

section "2. Clean repo scan"
run "$KIMSCAN" repo "$TMP/test-clean"
assert_rc "clean repo" 0
assert_contains "verdict PASS" "|   PASS"
CLEAN_ID=$(last_id)
assert_file "session.json exists" "$(session_file "$CLEAN_ID")"
assert_file "report.md exists" "$XDG_DATA_HOME/kimscanning/sessions/$CLEAN_ID/report.md"
if [ -d "$XDG_DATA_HOME/kimscanning/sessions/$CLEAN_ID/raw" ]; then
    ok "raw/ exists"
else
    bad "raw/ missing"
fi
if python3 - "$(session_file "$CLEAN_ID")" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "PASS", s["verdict"]
assert s["counts"] == {"critical": 0, "high": 0, "medium": 0, "low": 0}
PY
then
    ok "clean verdict/counts schema"
else
    bad "clean verdict/counts schema"
fi

section "2b. NDJSON --json"
run "$KIMSCAN" repo "$TMP/test-clean" --json
assert_rc "clean repo --json" 0
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
    ok "every stdout line is valid JSON"
else
    bad "invalid NDJSON"
fi

section "3. Leaky repo scan (first time)"
run "$KIMSCAN" repo "$TMP/test-leak"
assert_rc "leaky repo" 3
assert_contains "verdict FAIL" "|   FAIL"
ID1=$(last_id)
S1=$(session_file "$ID1")
assert_file "leaky session.json" "$S1"
if python3 - "$S1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "FAIL", s["verdict"]
assert s["counts"]["high"] >= 1, s["counts"]
f = [x for x in s["findings"] if x["tool"] == "gitleaks" and x["rule"] == "aws-access-token"]
assert f, [x["rule"] for x in s["findings"]]
assert f[0]["explanation"], f[0]
assert f[0]["explanation"]["what"], f[0]
assert f[0]["status"] == "new", f[0]["status"]
PY
then
    ok "AWS finding has an explanation and status new"
else
    bad "AWS finding missing explanation/status"
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
if [ -n "$FP" ]; then ok "AWS fp: $FP"; else bad "AWS fp not found"; fi

section "4. Second scan — status kept"
run "$KIMSCAN" repo "$TMP/test-leak"
assert_rc "leaky repo second time" 3
ID2=$(last_id)
S2=$(session_file "$ID2")
if python3 - "$S1" "$S2" "$FP" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
fp = sys.argv[3]
fa = next(x for x in a["findings"] if x["fp"] == fp)
fb = next(x for x in b["findings"] if x["fp"] == fp)
assert fa["status"] == fb["status"] == "new", (fa["status"], fb["status"])
assert fa["first_seen"] == fb["first_seen"], (fa["first_seen"], fb["first_seen"])
assert fb["last_seen"] >= fa["last_seen"], (fa["last_seen"], fb["last_seen"])
PY
then
    ok "status new kept; first_seen equal; last_seen updated"
else
    bad "status carry-over failed"
fi

section "5. status accepted + third scan"
run "$KIMSCAN" status "$ID1" "$FP" accepted
assert_rc "kimscan status" 0
run "$KIMSCAN" repo "$TMP/test-leak"
assert_rc "leaky repo third time" 3
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
assert fb["status"] == "new", fb["status"]
assert fc["status"] == "accepted", fc["status"]
PY
then
    ok "accepted status kept in the third scan even though the second session is fresh"
else
    bad "accepted status not kept"
fi

section "6. web without --authorized"
BEFORE=$(session_count)
run "$KIMSCAN" web http://127.0.0.1
assert_rc "web without authorization" 1
assert_contains "authorization message" "authorized"
AFTER=$(session_count)
if [ "$BEFORE" -eq "$AFTER" ]; then
    ok "no session created for a rejected scan"
else
    bad "session created although the scan was rejected ($BEFORE -> $AFTER)"
fi

section "7. rules --missing"
run "$KIMSCAN" rules --missing
assert_rc "rules --missing" 0
sed -n '1,16p' "$LAST_OUT" | sed 's/^/      /'
if grep -Fq "Rule ids without an explanation: 0" "$LAST_OUT"; then
    ok "no missing rule ids (reported honestly)"
elif grep -Eq '^  [a-zA-Z0-9._-]+/.*\(' "$LAST_OUT"; then
    ok "at least one rule id without an explanation is listed"
else
    bad "unexpected rules --missing output"
fi

section "8. No writes outside designated areas"
if [ -z "$(find "$TMP/cwd" -mindepth 1 -print -quit)" ]; then
    ok "test working directory stays empty"
else
    bad "files created in the test working directory"
    find "$TMP/cwd" -mindepth 1 -maxdepth 2 | sed 's/^/      /'
fi
DATA_ENTRIES=$(find "$XDG_DATA_HOME" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')
if [ "$DATA_ENTRIES" = "kimscanning " ]; then
    ok "XDG_DATA_HOME contains only kimscanning"
else
    bad "XDG_DATA_HOME contains other entries: $DATA_ENTRIES"
fi
if [ -e "$REPO/gate-out" ]; then
    bad "gate-out created inside the repo"
else
    ok "no gate-out in the repo"
fi

section "Summary"
echo "  Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
