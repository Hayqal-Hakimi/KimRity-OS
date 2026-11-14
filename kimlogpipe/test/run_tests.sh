#!/usr/bin/env bash
# KimLogPipe v2 test suite.
# Everything runs inside a temporary HOME/XDG_DATA_HOME/XDG_RUNTIME_DIR.
# Nothing is written to the real ~/.local/share or outside kimlogpipe/**.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="$ROOT/kimlogpipe/kimlogpipe"
KIMAI="$ROOT/kimai/kimai"
FIX="$ROOT/kimlogpipe/fixtures"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg"
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"

STORE="$XDG_DATA_HOME/kimlogpipe"
export KIMAI_NOTIFY=0
export KIMAI_SOCKET="$XDG_RUNTIME_DIR/kimai.sock"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

run_ok() {
  local desc="$1"; shift
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  printf '%s\n' "$out" >"$TMP/last.out"
  if [ "$rc" -eq 0 ]; then ok "$desc"; else
    bad "$desc (rc=$rc)"
    sed -n '1,40p' "$TMP/last.out"
  fi
  LAST_OUT="$TMP/last.out"
}

contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file"; then ok "$desc"; else
    bad "$desc (not found: $needle)"
    sed -n '1,50p' "$file"
  fi
}

not_contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file"; then
    bad "$desc (should not contain: $needle)"
    sed -n '1,50p' "$file"
  else ok "$desc"; fi
}

reset_store() { rm -rf "$STORE"; }

check_schema() {
  local file="$1" src="$2" count="$3" desc="$4"
  if python3 - "$file" "$src" "$count" <<'PY'
import json, re, sys
path, want_src, want_count = sys.argv[1], sys.argv[2], int(sys.argv[3])
keys = ["ts", "source", "host", "user", "src_ip", "action",
        "outcome", "raw_ref", "path"]
rows = []
with open(path, encoding="utf-8") as fh:
    for n, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        assert isinstance(obj, dict), f"line {n}: not an object"
        assert list(obj.keys()) == keys, f"line {n}: keys {list(obj.keys())}"
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z", obj["ts"]), f"line {n}: ts {obj['ts']}"
        assert obj["source"] == want_src, f"line {n}: source {obj['source']}"
        assert obj["outcome"] in ("success", "failed", "unknown"), f"line {n}: outcome"
        assert obj["raw_ref"], f"line {n}: empty raw_ref"
        assert isinstance(obj["user"], str) and isinstance(obj["src_ip"], str)
        assert isinstance(obj["path"], str)
        rows.append(obj)
assert len(rows) == want_count, f"count {len(rows)} != {want_count}"
PY
  then ok "$desc"; else bad "$desc"; fi
}

echo "== 0. py_compile =="
if python3 -m py_compile "$BIN"; then ok "kimlogpipe passes py_compile"; else bad "py_compile"; fi

echo
echo "== 1. rule listing (YAML and fallback parser) =="
"$BIN" rules >"$TMP/rules-py.out" 2>&1
if [ $? -eq 0 ]; then ok "kimlogpipe rules runs"; else bad "kimlogpipe rules"; fi
LAST_OUT="$TMP/rules-py.out"
contains "rules: ssh_bruteforce" "ssh_bruteforce" "$LAST_OUT"
contains "rules: sudo_fail" "sudo_fail" "$LAST_OUT"
contains "rules: audit_exec_watch" "audit_exec_watch" "$LAST_OUT"
contains "rules: etc_watch" "etc_watch" "$LAST_OUT"
contains "rules: threshold 5" "Threshold: 5 signals" "$LAST_OUT"
contains "rules: window 300" "300s" "$LAST_OUT"
contains "rules: watch list" "nmap, nc, curl, wget" "$LAST_OUT"
contains "rules: cooldown shown" "Cooldown: 900s" "$LAST_OUT"
KIMLOGPIPE_FORCE_MINI_YAML=1 "$BIN" rules >"$TMP/rules-mini.out" 2>&1
if diff -q "$TMP/rules-py.out" "$TMP/rules-mini.out" >/dev/null; then
  ok "the fallback YAML parser gives identical output"
else
  bad "the fallback YAML parser differs"; diff "$TMP/rules-py.out" "$TMP/rules-mini.out" | head
fi

echo
echo "== 2. ingest journald (real fixture) =="
reset_store
run_ok "ingest journald f_sshd.jsonl" "$BIN" ingest --source journald --file "$FIX/f_sshd.jsonl"
contains "journald: 40 events parsed" "Events parsed     : 40" "$LAST_OUT"
contains "journald: 0 invalid lines" "Invalid lines     : 0" "$LAST_OUT"
check_schema "$STORE/events.jsonl" journald 40 "events.jsonl journald: 40 rows, schema valid"

echo
echo "== 3. idempotent re-ingest =="
run_ok "re-ingest journald" "$BIN" ingest --source journald --file "$FIX/f_sshd.jsonl"
contains "dedupe: 0 new" "New events        : 0" "$LAST_OUT"
contains "dedupe: 40 duplicates" "Duplicates skipped: 40" "$LAST_OUT"
lines="$(wc -l <"$STORE/events.jsonl" | tr -d ' ')"
if [ "$lines" = "40" ]; then ok "dedupe: events.jsonl stays at 40 rows"; else bad "dedupe: $lines rows"; fi

echo
echo "== 4. ingest auditd (real fixture) =="
run_ok "ingest auditd f_audit.log" "$BIN" ingest --source auditd --file "$FIX/f_audit.log"
contains "auditd: 13 event groups" "Events parsed     : 13" "$LAST_OUT"
contains "auditd: store total 53" "Total in store    : 53" "$LAST_OUT"
if python3 - "$STORE/events.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
src = [r["source"] for r in rows]
assert src.count("auditd") == 13, src.count("auditd")
assert src.count("journald") == 40
PY
then ok "events.jsonl: 13 auditd + 40 journald"; else bad "auditd source count"; fi

echo
echo "== 5. detect on the real fixtures (honesty) =="
run_ok "detect all rules" "$BIN" detect
contains "detect: ssh_bruteforce no match" "ssh_bruteforce: no match" "$LAST_OUT"
contains "detect: sudo_fail not evaluable" "sudo_fail: not evaluable" "$LAST_OUT"
contains "detect: exec_watch not evaluable" "audit_exec_watch: not evaluable" "$LAST_OUT"
contains "detect: etc_watch no match" "etc_watch: no match" "$LAST_OUT"
contains "detect: 0 findings (nothing invented)" "Total findings: 0" "$LAST_OUT"
if python3 - "$STORE/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["findings"] == []
assert len(d["rules"]) == 4
assert {r["rule"] for r in d["rules"]} == {
    "ssh_bruteforce", "sudo_fail", "audit_exec_watch", "etc_watch"}
PY
then ok "findings.json: 0 findings, 4 rule decisions"; else bad "findings.json structure"; fi

echo
echo "== 6. report =="
run_ok "report runs" "$BIN" report
contains "report: title" "KIMLOGPIPE v2.0 REPORT" "$LAST_OUT"
contains "report: journald 40" "journald: 40" "$LAST_OUT"
contains "report: auditd 13" "auditd: 13" "$LAST_OUT"
contains "report: top keys" "TOP KEYS" "$LAST_OUT"
contains "report: honest empty state" "no key (no findings)" "$LAST_OUT"
contains "report: journald caveat" "Storage=volatile" "$LAST_OUT"
contains "report: QEMU NAT caveat" "10.0.2.2" "$LAST_OUT"
contains "report: PerSourcePenalties caveat" "drop connection" "$LAST_OUT"

echo
echo "== 7. ssh_bruteforce + sudo_fail (synthetic, current time) =="
reset_store
NOW="$(date +%s)"
python3 - "$TMP/ssh.jsonl" "$NOW" <<'PY'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
rows = []
def add(off, msg, ident="sshd-session"):
    rows.append({"__REALTIME_TIMESTAMP": str((now - off) * 1_000_000),
                 "__CURSOR": f"c{off}-{len(rows)}", "_HOSTNAME": "arch-uji",
                 "SYSLOG_IDENTIFIER": ident, "_COMM": ident, "MESSAGE": msg})
# 6 signals (5 failures + 1 drop) from the same IP within 180s
for off, msg in [
    (280, "Failed password for invalid user admin from 203.0.113.9 port 40001 ssh2"),
    (260, "Failed password for invalid user admin from 203.0.113.9 port 40002 ssh2"),
    (240, "Failed password for invalid user admin from 203.0.113.9 port 40003 ssh2"),
    (220, "Failed password for invalid user admin from 203.0.113.9 port 40004 ssh2"),
    (200, "Invalid user oracle from 203.0.113.9 port 40005"),
    (100, "drop connection #0 from 203.0.113.9 port 40006"),
]:
    add(off, msg)
# 3 failures (below threshold)
for off in (250, 230, 210):
    add(off, f"Failed password for root from 198.51.100.7 port 5000{off} ssh2")
# 5 failures spread over 390s (no 5 within 300s)
for off in (390, 290, 190, 90, 0):
    add(off, f"Failed password for root from 192.0.2.55 port 6000{off} ssh2")
# failed sudo
add(50, "pam_unix(sudo:auth): authentication failure; logname= uid=0 euid=0 "
        "tty=/dev/pts/0 ruser= user=root", "sudo")
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
run_ok "ingest synthetic ssh/sudo" "$BIN" ingest --source journald --file "$TMP/ssh.jsonl"
run_ok "detect synthetic ssh/sudo" "$BIN" detect
contains "bruteforce: 1 finding" "ssh_bruteforce: 1 finding" "$LAST_OUT"
contains "bruteforce: key 203.0.113.9" "key=203.0.113.9 count=6" "$LAST_OUT"
not_contains "bruteforce: below-threshold IP not reported" "198.51.100.7" "$LAST_OUT"
not_contains "bruteforce: spread-out IP not reported" "192.0.2.55" "$LAST_OUT"
contains "sudo_fail: 1 finding" "sudo_fail: 1 finding" "$LAST_OUT"
contains "sudo_fail: key root" "key=root count=1" "$LAST_OUT"
if python3 - "$STORE/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bf = [f for f in d["findings"] if f["rule"] == "ssh_bruteforce"]
assert len(bf) == 1, bf
f = bf[0]
assert f["key"] == "203.0.113.9" and f["count"] == 6
assert len(f["evidence"]) == 6
assert all(e["line"] for e in f["evidence"])
assert f["first_ts"] < f["last_ts"]
assert f["summary"].startswith("6 failed SSH")
PY
then ok "findings.json: bruteforce 6 signals + 6 evidence lines"; else bad "bruteforce findings"; fi

echo
echo "== 8. --since window =="
run_ok "detect --since 10m" "$BIN" detect --since 10m
contains "--since 10m: still finds" "ssh_bruteforce: 1 finding" "$LAST_OUT"
run_ok "detect --since 0s" "$BIN" detect --since 0s
contains "--since 0s: no events in window" "no events in the store/window" "$LAST_OUT"

echo
echo "== 9. report with findings + top key =="
run_ok "detect again without --since" "$BIN" detect
run_ok "report after findings" "$BIN" report
contains "report: bruteforce finding" "ssh_bruteforce [high]: 1 finding" "$LAST_OUT"
contains "report: top key 203.0.113.9" "203.0.113.9 (6 events" "$LAST_OUT"

echo
echo "== 10. audit_exec_watch + sudo (synthetic auditd) =="
reset_store
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.001:9001): arch=c000003e syscall=59 success=yes exit=0 a0=55d0 a1=55e0 a2=55f0 a3=0 items=2 ppid=1000 pid=1001 auid=1000 uid=1000 gid=1000 euid=1000 comm=\"nmap\" exe=\"/usr/bin/nmap\" key=(null) SYSCALL=execve AUID=\"alice\" UID=\"alice\""
  echo "type=EXECVE msg=audit($NOW.001:9001): argc=2 a0=\"nmap\" a1=\"-sV\""
  echo "type=PROCTITLE msg=audit($NOW.001:9001): proctitle=6E6D6170"
  echo "type=SYSCALL msg=audit($NOW.002:9002): arch=c000003e syscall=59 success=yes exit=0 a0=55d0 a1=55e0 a2=55f0 a3=0 items=2 ppid=1000 pid=1002 auid=1000 uid=1000 gid=1000 euid=1000 comm=\"ls\" exe=\"/usr/bin/ls\" key=(null) SYSCALL=execve AUID=\"alice\" UID=\"alice\""
  echo "type=USER_AUTH msg=audit($NOW.003:9003): pid=2000 uid=0 auid=1000 ses=3 msg='op=PAM:authentication grantors=pam_unix acct=\"alice\" exe=\"/usr/bin/sudo\" hostname=10.0.2.2 addr=10.0.2.2 terminal=/dev/pts/0 res=failed' AUID=\"alice\""
} >"$TMP/audit.log"
run_ok "ingest synthetic auditd" "$BIN" ingest --source auditd --file "$TMP/audit.log"
contains "auditd synthetic: 3 groups" "Events parsed     : 3" "$LAST_OUT"
if python3 - "$STORE/events.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
acts = sorted(r["action"] for r in rows)
assert acts == ["execve:ls", "execve:nmap", "sudo_fail"], acts
nm = [r for r in rows if r["action"] == "execve:nmap"][0]
assert nm["user"] == "alice" and nm["outcome"] == "success"
su = [r for r in rows if r["action"] == "sudo_fail"][0]
assert su["src_ip"] == "10.0.2.2" and su["user"] == "alice" and su["outcome"] == "failed"
PY
then ok "auditd: execve:nmap, execve:ls and sudo_fail parsed correctly"; else bad "auditd synthetic parsing"; fi
run_ok "detect synthetic auditd" "$BIN" detect
contains "exec_watch: 1 finding" "audit_exec_watch: 1 finding" "$LAST_OUT"
contains "exec_watch: nmap by alice" "nmap by alice" "$LAST_OUT"
not_contains "exec_watch: ls not reported" "ls by" "$LAST_OUT"
contains "sudo_fail auditd: 1 finding" "sudo_fail: 1 finding" "$LAST_OUT"
if python3 - "$STORE/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = [f for f in d["findings"] if f["rule"] == "audit_exec_watch"]
assert len(ex) == 1 and ex[0]["count"] == 1 and ex[0]["key"] == "alice"
assert 'exe="/usr/bin/nmap"' in ex[0]["evidence"][0]["line"]
PY
then ok "exec_watch: evidence contains exe=/usr/bin/nmap"; else bad "exec_watch evidence"; fi

echo
echo "== 11. etc_watch (synthetic auditd PATH record) =="
reset_store
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.010:77): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=900 auid=1000 uid=1000 comm=\"bash\" exe=\"/usr/bin/bash\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.010:77): item=0 name=\"/etc/passwd\" inode=1234 nametype=CREATE"
  echo "type=SYSCALL msg=audit($NOW.011:78): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=901 auid=1000 uid=1000 comm=\"bash\" exe=\"/usr/bin/bash\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.011:78): item=0 name=\"/etc/shadow\" inode=1235 nametype=CREATE"
} >"$TMP/audit-etc.log"
run_ok "ingest etc_watch records" "$BIN" ingest --source auditd --file "$TMP/audit-etc.log"
run_ok "detect etc_watch" "$BIN" detect
contains "etc_watch: 2 findings (one per path)" "etc_watch: 2 finding" "$LAST_OUT"
if python3 - "$STORE/events.jsonl" "$STORE/findings.json" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, rows
assert all(r["action"] == "etc_change" for r in rows), rows
assert {r["path"] for r in rows} == {"/etc/passwd", "/etc/shadow"}, rows
d = json.load(open(sys.argv[2]))
f = [x for x in d["findings"] if x["rule"] == "etc_watch"]
assert len(f) == 2, f
assert {x["key"] for x in f} == {"/etc/passwd", "/etc/shadow"}
assert all(x["severity"] == "medium" for x in f)
PY
then ok "etc_change events carry the watched path and no AIDE is needed"; else bad "etc_watch findings"; fi

echo
echo "== 11b. real sshd penalty formats (guest regression) =="
reset_store
NOW="$(date +%s)"
python3 - "$TMP/penalty.jsonl" "$NOW" <<'PY'
import json, sys
path, now = sys.argv[1], int(sys.argv[2])
rows = []
def add(off, msg):
    rows.append({"__REALTIME_TIMESTAMP": str((now - off) * 1_000_000),
                 "__CURSOR": f"p{off}-{len(rows)}", "_HOSTNAME": "arch-uji",
                 "SYSLOG_IDENTIFIER": "sshd-session", "_COMM": "sshd-session",
                 "MESSAGE": msg})
# exactly the shapes seen in the QEMU guest (PerSourcePenalties active)
for i in range(6):
    add(200 - i * 10,
        f"drop connection #0 from [10.0.2.2]:6036{i} on [10.0.2.15]:22 "
        "penalty: failed authentication")
for i in range(4):
    add(120 - i * 5,
        f"Connection closed by authenticating user root 10.0.2.2 port 6031{i} [preauth]")
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
run_ok "ingest sshd penalty lines" "$BIN" ingest --source journald --file "$TMP/penalty.jsonl"
run_ok "detect sshd penalty lines" "$BIN" detect
if python3 - "$STORE/events.jsonl" "$STORE/findings.json" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 10, rows
ips = {r["src_ip"] for r in rows}
# [10.0.2.2] is the remote peer, [10.0.2.15] is the local address.
assert ips == {"10.0.2.2"}, ips
assert {r["action"] for r in rows} == {"ssh_drop"}, rows
d = json.load(open(sys.argv[2]))
bf = [f for f in d["findings"] if f["rule"] == "ssh_bruteforce"]
assert len(bf) == 1, bf
assert bf[0]["key"] == "10.0.2.2" and bf[0]["count"] == 10, bf[0]
PY
then ok "sshd penalty lines: 10 signals, src_ip 10.0.2.2, one finding"; else bad "sshd penalty parsing"; fi

echo
echo "== 11c. audit rule load is not a file change (guest regression) =="
reset_store
NOW="$(date +%s)"
{
  # augenrules --load: CONFIG_CHANGE + SYSCALL + a PARENT-only PATH record
  echo "type=CONFIG_CHANGE msg=audit($NOW.001:187): auid=4294967295 ses=4294967295 op=add_rule key=\"etc_watch\" list=4 res=1AUID=\"unset\""
  echo "type=SYSCALL msg=audit($NOW.001:187): arch=c000003e syscall=44 success=yes exit=1076 a0=3 a1=7ffc a2=434 a3=0 items=0 ppid=1 pid=523 auid=1000 uid=0 gid=0 euid=0 comm=\"auditctl\" exe=\"/usr/bin/auditctl\" key=\"etc_watch\" SYSCALL=sendto AUID=\"hayqal\" UID=\"root\" GID=\"root\""
  echo "type=PATH msg=audit($NOW.001:187): item=0 name=\"/etc/\" inode=263 nametype=PARENT"
  echo "type=PROCTITLE msg=audit($NOW.001:187): proctitle=617564697463746C"
  # a real file change: CREATE record first, PARENT record second
  echo "type=SYSCALL msg=audit($NOW.002:188): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=2 ppid=1 pid=524 auid=1000 uid=1000 comm=\"tee\" exe=\"/usr/bin/tee\" key=\"etc_watch\" SYSCALL=openat AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.002:188): item=0 name=\"/etc/hosts\" inode=1234 nametype=CREATE"
  echo "type=PATH msg=audit($NOW.002:188): item=1 name=\"/etc/\" inode=263 nametype=PARENT"
} >"$TMP/audit-load.log"
run_ok "ingest rule-load + real change" "$BIN" ingest --source auditd --file "$TMP/audit-load.log"
run_ok "detect rule-load + real change" "$BIN" detect
if python3 - "$STORE/events.jsonl" "$STORE/findings.json" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
acts = sorted(r["action"] for r in rows)
assert acts == ["audit_rule_load", "etc_change"], acts
rule = [r for r in rows if r["action"] == "audit_rule_load"][0]
change = [r for r in rows if r["action"] == "etc_change"][0]
assert change["path"] == "/etc/hosts", change
d = json.load(open(sys.argv[2]))
f = [x for x in d["findings"] if x["rule"] == "etc_watch"]
assert len(f) == 1, f
assert f[0]["key"] == "/etc/hosts", f[0]
PY
then ok "rule load -> audit_rule_load (no finding); real change keeps /etc/hosts"; else bad "rule-load filtering"; fi

echo
echo "== 12. storage isolation =="
if [ ! -e "$HOME/.local/share/kimlogpipe" ]; then
  ok "no store under the real HOME (XDG respected)"
else
  bad "the store was written to HOME/.local/share"
fi
case "$(cd "$STORE" && pwd)" in
  "$XDG_DATA_HOME"/*) ok "the store lives under XDG_DATA_HOME" ;;
  *) bad "the store is outside XDG_DATA_HOME" ;;
esac

echo
echo "== 13. follow: audit tail -> rule -> KimAI event =="
reset_store
rm -rf "$STORE"
AUDIT="$TMP/live-audit.log"
export KIMLOGPIPE_AUDIT_LOG="$AUDIT"
NOW="$(date +%s)"
echo "type=SYSCALL msg=audit($NOW.001:1): syscall=59 success=yes exe=\"/usr/bin/ls\" key=(null) SYSCALL=execve AUID=\"hayqal\"" >"$AUDIT"

"$KIMAI" start >"$TMP/kimai.log" 2>&1 &
KIMAI_PID=$!
for _ in $(seq 1 50); do [ -S "$KIMAI_SOCKET" ] && break; sleep 0.1; done
if [ -S "$KIMAI_SOCKET" ]; then ok "KimAI started for the integration test"; else bad "KimAI socket did not appear"; fi

"$BIN" follow --source auditd >"$TMP/follow.log" 2>&1 &
FOLLOW_PID=$!
sleep 1.5
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.010:77): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=900 auid=1000 uid=1000 comm=\"bash\" exe=\"/usr/bin/bash\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.010:77): item=0 name=\"/etc/passwd\" inode=1234 nametype=CREATE"
} >>"$AUDIT"
sleep 3

contains "follow: finding printed" "FINDING [medium] etc_watch key=/etc/passwd" "$TMP/follow.log"
contains "follow: KimAI accepted the event" "KimAI accepted the event" "$TMP/follow.log"
if python3 - "$STORE/findings.jsonl" "$XDG_DATA_HOME/kimai/events.jsonl" <<'PY'
import json, sys
findings = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(findings) == 1, findings
f = findings[0]
assert f["rule"] == "etc_watch" and f["key"] == "/etc/passwd", f
assert f["evidence"] and f["evidence"][0]["line"].startswith("type=SYSCALL"), f
events = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert len(events) == 1, events
e = events[0]
assert e["source"] == "kimlogpipe" and e["kind"] == "etc_watch", e
assert e["severity"] == "medium", e
assert e["data"]["key"] == "/etc/passwd", e
assert e["data"]["count"] == 1, e
PY
then ok "follow: findings.jsonl and KimAI events.jsonl agree"; else bad "follow integration data"; fi

echo
echo "== 14. follow: audit offset survives a restart =="
kill -TERM "$FOLLOW_PID" 2>/dev/null
wait "$FOLLOW_PID" 2>/dev/null
FOLLOW_RC=$?
if [ "$FOLLOW_RC" -eq 0 ]; then ok "follow exits 0 on SIGTERM"; else bad "follow exit code $FOLLOW_RC"; fi
BEFORE="$(wc -l <"$STORE/events.jsonl" | tr -d ' ')"
OFFSET="$(python3 - "$STORE/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(s.get("audit", {}).get("offset", 0))
PY
)"
if [ "$OFFSET" -gt 0 ]; then ok "state.json records the audit offset ($OFFSET)"; else bad "audit offset not saved"; fi

"$BIN" follow --source auditd >"$TMP/follow2.log" 2>&1 &
FOLLOW_PID=$!
sleep 2
AFTER="$(wc -l <"$STORE/events.jsonl" | tr -d ' ')"
if [ "$BEFORE" = "$AFTER" ]; then ok "restart does not re-read old audit lines ($AFTER rows)"; else bad "restart duplicated events ($BEFORE -> $AFTER)"; fi

echo
echo "== 15. follow: KimAI down -> tools-only, no crash =="
"$KIMAI" stop >/dev/null 2>&1
sleep 0.3
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.020:88): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=902 auid=1000 uid=1000 comm=\"bash\" exe=\"/usr/bin/bash\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.020:88): item=0 name=\"/etc/group\" inode=1236 nametype=CREATE"
} >>"$AUDIT"
sleep 3
if kill -0 "$FOLLOW_PID" 2>/dev/null; then ok "follow keeps running without KimAI"; else bad "follow died when KimAI was down"; fi
contains "follow: tools-only fallback logged" "continuing in tools-only mode" "$TMP/follow2.log"
if python3 - "$STORE/findings.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert any(r["key"] == "/etc/group" for r in rows), rows
PY
then ok "follow: finding still recorded while KimAI is down"; else bad "tools-only finding missing"; fi
kill -TERM "$FOLLOW_PID" 2>/dev/null
wait "$FOLLOW_PID" 2>/dev/null

echo
echo "== 15b. follow: audit log appears/becomes readable later =="
reset_store
rm -rf "$STORE"
LATE="$TMP/late-audit.log"
rm -f "$LATE"
export KIMLOGPIPE_AUDIT_LOG="$LATE"
"$BIN" follow --source auditd >"$TMP/follow-late.log" 2>&1 &
LATE_PID=$!
sleep 2
contains "late audit log: startup says unreadable" "is not readable" "$TMP/follow-late.log"
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.030:99): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=903 auid=1000 uid=1000 comm=\"bash\" exe=\"/usr/bin/bash\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.030:99): item=0 name=\"/etc/passwd\" inode=1240 nametype=CREATE"
} >"$LATE"
sleep 3
contains "late audit log: recovery is logged, no restart needed" "is readable again" "$TMP/follow-late.log"
if python3 - "$STORE/findings.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert any(r["rule"] == "etc_watch" and r["key"] == "/etc/passwd" for r in rows), rows
PY
then ok "late audit log: etc_watch fires after the log appears"; else bad "late audit log finding missing"; fi
kill -TERM "$LATE_PID" 2>/dev/null
wait "$LATE_PID" 2>/dev/null
unset KIMLOGPIPE_AUDIT_LOG

echo
echo "== 15c. follow: first run does not replay old audit history =="
reset_store
rm -rf "$STORE"
HIST="$TMP/hist-audit.log"
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.040:120): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=904 auid=1000 uid=1000 comm=\"tee\" exe=\"/usr/bin/tee\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.040:120): item=0 name=\"/etc/passwd\" inode=1241 nametype=CREATE"
  echo "type=PATH msg=audit($NOW.040:120): item=1 name=\"/etc/\" inode=263 nametype=PARENT"
} >"$HIST"
export KIMLOGPIPE_AUDIT_LOG="$HIST"
"$BIN" follow --source auditd >"$TMP/follow-hist.log" 2>&1 &
HIST_PID=$!
sleep 2.5
contains "history: startup says it starts at the end" "history is not replayed" "$TMP/follow-hist.log"
FINDINGS_BEFORE=0
[ -f "$STORE/findings.jsonl" ] && FINDINGS_BEFORE="$(wc -l <"$STORE/findings.jsonl" | tr -d ' ')"
if [ "$FINDINGS_BEFORE" = "0" ]; then ok "history: no finding for the pre-existing change"; else bad "history was replayed ($FINDINGS_BEFORE findings)"; fi
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.041:121): arch=c000003e syscall=257 success=yes exit=3 a0=ffffff9c a1=55f0 a2=241 a3=1b6 items=1 ppid=1 pid=905 auid=1000 uid=1000 comm=\"tee\" exe=\"/usr/bin/tee\" key=\"etc_watch\" AUID=\"hayqal\" UID=\"hayqal\""
  echo "type=PATH msg=audit($NOW.041:121): item=0 name=\"/etc/shadow\" inode=1242 nametype=CREATE"
} >>"$HIST"
sleep 3
if python3 - "$STORE/findings.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 1, rows
assert rows[0]["key"] == "/etc/shadow", rows[0]
PY
then ok "history: only the change after startup is reported"; else bad "history: new change not reported cleanly"; fi
kill -TERM "$HIST_PID" 2>/dev/null
wait "$HIST_PID" 2>/dev/null
unset KIMLOGPIPE_AUDIT_LOG

echo
echo "== 16. follow: live journald brute force (skipped if unreadable) =="
if journalctl -o json -n 1 >/dev/null 2>&1; then
  reset_store
  "$BIN" follow --source journald >"$TMP/follow3.log" 2>&1 &
  JPID=$!
  sleep 2
  for i in 1 2 3 4 5 6; do
    logger -t sshd-session "Failed password for invalid user probe from 198.51.100.99 port 4100$i ssh2"
  done
  sleep 3
  if grep -q "FINDING \[high\] ssh_bruteforce key=198.51.100.99 count=6" "$TMP/follow3.log"; then
    ok "follow: live journal lines produced one bruteforce finding"
  else
    bad "follow: no live bruteforce finding"
    sed -n '1,30p' "$TMP/follow3.log"
  fi
  kill -TERM "$JPID" 2>/dev/null
  wait "$JPID" 2>/dev/null
else
  ok "follow: journald not readable for this user, live test skipped"
fi

echo
echo "== 17. status =="
run_ok "status runs" "$BIN" status
contains "status: version" "KIMLOGPIPE v2.0 STATUS" "$LAST_OUT"
contains "status: store" "Store" "$LAST_OUT"
contains "status: KimAI socket line" "KimAI socket" "$LAST_OUT"

echo
echo "=================================================="
echo "RESULT: $PASS passed, $FAIL failed"
echo "=================================================="
[ "$FAIL" -eq 0 ]
