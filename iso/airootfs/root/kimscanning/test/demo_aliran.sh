#!/usr/bin/env bash
# demo_aliran.sh — KimScanning workflow demo for beginners.
#
# Run:
#   bash kimscanning/test/demo_aliran.sh
#
# All demo files (HOME, session data, targets) are created in a temp folder.
# None of your real files are touched. To keep the demo folder after it
# finishes: KEEP=1 bash kimscanning/test/demo_aliran.sh
#
# This script exits with:
#   0  every expectation held
#   1  some expectation failed
#   4  scanner tools missing/incomplete (demo still runs)

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# ---------------------------------------------------------------- find kimscan
KIMSCAN=${KIMSCAN:-}
if [ -z "$KIMSCAN" ]; then
    if [ -x "$SCRIPT_DIR/../kimscan" ]; then
        KIMSCAN="$SCRIPT_DIR/../kimscan"
    elif command -v kimscan >/dev/null 2>&1; then
        KIMSCAN=$(command -v kimscan)
    elif [ -x /usr/local/bin/kimscan ]; then
        KIMSCAN=/usr/local/bin/kimscan
    fi
fi
if [ -z "$KIMSCAN" ] || [ ! -x "$KIMSCAN" ]; then
    echo "ERROR: kimscan not found." >&2
    echo "Try: KIMSCAN=/path/to/kimscan bash $0" >&2
    exit 1
fi
# Show the full, tidy path in the demo.
KIMSCAN=$(readlink -f "$KIMSCAN" 2>/dev/null || printf '%s' "$KIMSCAN")

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is needed to read sessions." >&2
    exit 1
fi

# ------------------------------------------------------------- demo environment
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kimscan-demo.XXXXXX") || exit 1
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        echo
        echo "Demo folder kept: $TMP"
    else
        rm -rf "$TMP"
        echo
        echo "Temp demo folder has been deleted."
    fi
}
trap cleanup EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export TRIVY_CACHE_DIR="$TMP/trivy-cache"
export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0
mkdir -p "$HOME" "$XDG_DATA_HOME" "$TMP/logs"
cd "$TMP" || exit 1

CLEAN="$TMP/target-clean"
BAD="$TMP/target-leak"
SESSIONS="$XDG_DATA_HOME/kimscanning/sessions"
LOGS="$TMP/logs"

FAILED=0
ENV_INCOMPLETE=0
MISSING_REPO=""

pass() { echo "  [OK]    $*"; }
fail() { echo "  [FAIL]  $*"; FAILED=1; }
note() { echo "  [INFO]  $*"; }

step() {
    echo
    echo "======================================================================"
    echo " STEP $1: $2"
    echo "======================================================================"
}

run_capture() {
    # run_capture <logfile> <command...>
    local log=$1
    shift
    "$@" >"$log" 2>&1
    local rc=$?
    cat "$log"
    return "$rc"
}

last_session() {
    ls -1 "$SESSIONS" 2>/dev/null | sort | tail -n 1
}

session_json() {
    echo "$SESSIONS/$1/session.json"
}

# finding fp: prefer gitleaks/aws-access-token, else take the first finding.
fp_of() {
    "$KIMSCAN" show "$1" --json 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
fs = s.get("findings") or []
for f in fs:
    if f.get("tool") == "gitleaks" and f.get("rule") == "aws-access-token" and f.get("fp"):
        print(f["fp"]); raise SystemExit
for f in fs:
    if f.get("fp"):
        print(f["fp"]); raise SystemExit
'
}

# count gitleaks/aws-access-token findings in one session
aws_count_of() {
    local sfile
    sfile=$(session_json "$1")
    if [ ! -f "$sfile" ]; then
        echo "0"
        return
    fi
    python3 - "$sfile" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(0); raise SystemExit
n = sum(1 for f in (s.get("findings") or [])
        if f.get("tool") == "gitleaks" and f.get("rule") == "aws-access-token")
print(n)
PY
}

# check the status of one fp in one session; prints the status or "none"
status_of() {
    local sfile
    sfile=$(session_json "$1")
    python3 - "$sfile" "$2" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("none"); raise SystemExit
for f in s.get("findings") or []:
    if f.get("fp") == sys.argv[2]:
        print(f.get("status", "none")); raise SystemExit
print("none")
PY
}

# ------------------------------------------------------------------ start demo
echo "======================================================================"
echo " KIMSCANNING DEMO — workflow for beginners"
echo "======================================================================"
echo " kimscan : $KIMSCAN"
echo " folder  : $TMP (temp, touches no real files)"
echo
echo " This demo scans a clean folder and a folder deliberately containing"
echo " a fake AWS key, then shows how to read the verdict and mark actions."

# ---------------------------------------------------------------- 1. doctor
step 1 "Check available tools (doctor)"
"$KIMSCAN" doctor >"$LOGS/doctor.log" 2>&1
DOCTOR_RC=$?
cat "$LOGS/doctor.log"
if [ "$DOCTOR_RC" -ne 0 ]; then
    fail "doctor failed (exit $DOCTOR_RC)"
else
    pass "doctor finished (exit 0)"
fi

for t in gitleaks semgrep trivy; do
    if ! command -v "$t" >/dev/null 2>&1 ||
        grep -Eq "^$t[[:space:]].*available: no([[:space:]]|$)" "$LOGS/doctor.log"; then
        MISSING_REPO="$MISSING_REPO $t"
    fi
done
MISSING_REPO=${MISSING_REPO# }
if [ -n "$MISSING_REPO" ]; then
    ENV_INCOMPLETE=1
    note "MISSING TOOLS:$MISSING_REPO"
    note "The demo still runs, but repo scans CANNOT pass without these tools."
    note "Verdicts below are reported as-is — no fake verdicts."
else
    pass "gitleaks, semgrep, trivy available"
fi

if grep -q "gate.py : .*(MISSING)" "$LOGS/doctor.log"; then
    echo "ERROR: gate.py not found. The demo cannot continue scanning." >&2
    exit 1
fi

# ------------------------------------------------------- 2. target + clean
step 2 "Prepare targets and scan the CLEAN folder"
mkdir -p "$CLEAN" "$BAD"
cat >"$CLEAN/hello.py" <<'PY'
def greet(name):
    return f"Hello, {name}!"
PY
printf '# Example project\n\nThis folder is clean. No secrets.\n' >"$CLEAN/README.md"

echo "  Clean folder : $CLEAN"
echo "  Command      : kimscan repo $CLEAN"
echo
run_capture "$LOGS/clean.log" "$KIMSCAN" repo "$CLEAN"
CLEAN_RC=$?
CLEAN_ID=$(last_session)
echo
echo "  Exit code: $CLEAN_RC (expectation 0 = PASS)"
CLEAN_AWS=$(aws_count_of "$CLEAN_ID")
if [ "$CLEAN_RC" -eq 0 ]; then
    pass "clean folder PASS (exit 0)"
elif [ -n "$MISSING_REPO" ]; then
    note "CANNOT VERIFY: tools missing, so the gate cannot produce PASS."
else
    fail "clean folder should exit 0, got $CLEAN_RC"
fi
if [ "$CLEAN_AWS" -eq 0 ]; then
    pass "no AWS key in the clean folder"
else
    fail "clean folder contains $CLEAN_AWS AWS findings (should be none)"
fi

# ------------------------------------------------------------ 3. leaky folder
step 3 "Scan the LEAKY folder (random AWS key planted)"
# Gitleaks rejects AKIAIOSFODNN7EXAMPLE (allowlist), so generate a new key.
AWS_KEY="AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16 || true)"
printf 'AWS_ACCESS_KEY_ID=%s\n' "$AWS_KEY" >"$BAD/config.env"

echo "  Leaky folder : $BAD"
echo "  Key planted  : $AWS_KEY"
echo "  File         : config.env"
echo "  Command      : kimscan repo $BAD"
echo
run_capture "$LOGS/leak.log" "$KIMSCAN" repo "$BAD"
BAD_RC=$?
BAD_ID=$(last_session)
echo
echo "  Exit code: $BAD_RC (expectation 3 = FAIL)"
BAD_AWS=$(aws_count_of "$BAD_ID")
if [ "$BAD_RC" -eq 3 ]; then
    pass "leaky folder FAIL (exit 3)"
else
    fail "leaky folder should exit 3, got $BAD_RC"
fi
if [ "$BAD_AWS" -ge 1 ]; then
    pass "gitleaks/aws-access-token detected ($BAD_AWS findings)"
else
    if [ -n "$MISSING_REPO" ]; then
        ENV_INCOMPLETE=1
        note "CANNOT VERIFY: gitleaks missing, the AWS key could not be detected."
    else
        fail "AWS key not detected in the leaky folder"
    fi
fi

# ------------------------------------------------------------------- 4. list
step 4 "List all sessions (list)"
run_capture "$LOGS/list.log" "$KIMSCAN" list
LIST_RC=$?
echo
echo "  Exit code: $LIST_RC (expectation 0)"
SESSION_COUNT=$(ls -1 "$SESSIONS" 2>/dev/null | wc -l | tr -d ' ')
if [ "$LIST_RC" -eq 0 ] && [ "$SESSION_COUNT" -ge 2 ] && grep -q "$BAD_ID" "$LOGS/list.log"; then
    pass "list shows $SESSION_COUNT sessions, including $BAD_ID"
else
    fail "list did not show the sessions as expected"
fi

# ------------------------------------------------------------------- 5. show
step 5 "View one full session (show)"
echo "  Command: kimscan show $BAD_ID"
echo
run_capture "$LOGS/show.log" "$KIMSCAN" show "$BAD_ID"
SHOW_RC=$?
echo
echo "  Exit code: $SHOW_RC (expectation 0)"
if [ "$SHOW_RC" -eq 0 ] && grep -q "FINDINGS" "$LOGS/show.log"; then
    pass "show displayed the session details"
else
    fail "show failed to display the session"
fi

FP=$(fp_of "$BAD_ID")
if [ -n "$FP" ]; then
    pass "finding fp chosen: $FP"
    echo "  This fp will be marked 'accepted' in step 6."
    echo "  (If the fp is not visible in the normal output, use: kimscan show $BAD_ID --json)"
else
    fail "fp not found in session $BAD_ID"
fi

# ----------------------------------------------------------------- 6. status
step 6 "Mark one finding as 'accepted' (status)"
if [ -z "$FP" ]; then
    fail "cannot run status without an fp"
else
    echo "  Command: kimscan status $BAD_ID $FP accepted"
    echo
    run_capture "$LOGS/status.log" "$KIMSCAN" status "$BAD_ID" "$FP" accepted
    STATUS_RC=$?
    echo
    echo "  Exit code: $STATUS_RC (expectation 0)"
    if [ "$STATUS_RC" -eq 0 ] && grep -q "accepted" "$LOGS/status.log"; then
        pass "finding status changed to 'accepted'"
    else
        fail "status was not changed successfully"
    fi
fi

# ------------------------------------------------- 7. rescan (status carried)
step 7 "Rescan the same folder — the status should carry over"
echo "  Command: kimscan repo $BAD"
echo
run_capture "$LOGS/leak2.log" "$KIMSCAN" repo "$BAD"
BAD2_RC=$?
BAD2_ID=$(last_session)
echo
echo "  Exit code: $BAD2_RC (expectation 3, verdict unchanged)"
if [ "$BAD2_RC" -eq 3 ]; then
    pass "leaky folder still FAIL (exit 3)"
else
    fail "second scan should exit 3, got $BAD2_RC"
fi

if [ -n "$FP" ] && [ "$BAD2_ID" != "$BAD_ID" ]; then
    CARRIED=$(status_of "$BAD2_ID" "$FP")
    echo "  Finding fp $FP in the new session: status=$CARRIED"
    grep -F "gitleaks/aws-access-token" "$LOGS/leak2.log" | head -n 1 | sed 's/^/  Output line: /'
    if [ "$CARRIED" = "accepted" ]; then
        pass "'accepted' status carried across scans"
    else
        fail "status not carried over (got '$CARRIED')"
    fi
else
    fail "could not check cross-scan status"
fi

# ------------------------------------------------------------------ 8. rules
step 8 "Check explanation coverage (rules --missing)"
run_capture "$LOGS/rules.log" "$KIMSCAN" rules --missing
RULES_RC=$?
echo
echo "  Exit code: $RULES_RC (expectation 0)"
if [ "$RULES_RC" -eq 0 ]; then
    pass "missing-rules list displayed"
else
    fail "rules --missing failed"
fi

# ------------------------------------------------------------------ summary
echo
echo "======================================================================"
echo " SUMMARY — what it means and what to do"
echo "======================================================================"
echo
echo " PASS (exit 0)"
echo "   Nothing crossed the threshold. For this demo, the clean folder PASSED."
echo "   Do: continue your work."
echo
echo " CONDITIONAL (exit 2)"
echo "   Medium issues exist, no high/critical. Do: fix before shipping"
echo "   to production."
echo
echo " FAIL (exit 3)"
echo "   High/critical issues exist, OR a scanner tool failed to run."
echo "   Do: do not ship. Remove the secret / fix the issue, then scan again."
echo "   In this demo, the AWS key in the leaky folder caused FAIL."
echo
echo " Error (exit 1)"
echo "   Wrong usage, or missing --authorized for web/server."
echo
echo " Finding status (new / accepted / fixed)"
echo "   Status records your action, it does NOT change the verdict."
echo "   After marking 'accepted', the AWS key is still there, so the second"
echo "   scan stays FAIL — but that finding no longer shows as 'new'."
echo
echo " What to do next on your real folder:"
echo "   1. kimscan repo ~/your-project"
echo "   2. kimscan list                  # find the session id"
echo "   3. kimscan show <id>             # read the findings"
echo "   4. kimscan status <id> <fp> fixed   # after you fix it"
echo
echo " For websites/hosts (active scans), --authorized is REQUIRED:"
echo "   kimscan web https://your-site.example --authorized"
echo "   kimscan server 192.168.1.10 --authorized"
echo "   Without written authorization, do not scan other people's hosts."
echo
echo " Sessions are stored at: $SESSIONS"
if [ "${KEEP:-0}" = "1" ]; then
    echo " Demo folder kept because KEEP=1."
else
    echo " This demo folder will be deleted after the script ends."
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "DEMO RESULT: FAIL — some expectation did not hold."
    exit 1
elif [ "$ENV_INCOMPLETE" -ne 0 ]; then
    echo "DEMO RESULT: INCOMPLETE — missing tools:$MISSING_REPO."
    echo "The demo still ran and reported the real state, without fake verdicts."
    exit 4
else
    echo "DEMO RESULT: COMPLETE — all expectations held."
    exit 0
fi
