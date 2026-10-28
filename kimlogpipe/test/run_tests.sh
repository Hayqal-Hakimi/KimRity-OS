#!/usr/bin/env bash
# KimLogPipe v1 - rangka ujian.
# Menjalankan semua ujian dalam HOME/XDG_DATA_HOME sementara. Tiada apa-apa
# ditulis ke ~/.local/share sebenar atau ke luar kimlogpipe/** + stor sementara.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="$ROOT/kimlogpipe/kimlogpipe"
FIX="$ROOT/kimlogpipe/fixtures"

TMP="$(mktemp -d)" || { echo "GAGAL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg"
mkdir -p "$HOME" "$XDG_DATA_HOME"

STORE="$XDG_DATA_HOME/kimlogpipe"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'LULUS: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'GAGAL: %s\n' "$1"; }

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
    bad "$desc (tidak jumpa: $needle)"
    sed -n '1,50p' "$file"
  fi
}

not_contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -qF -- "$needle" "$file"; then
    bad "$desc (sepatutnya tiada: $needle)"
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
        "outcome", "raw_ref"]
rows = []
with open(path, encoding="utf-8") as fh:
    for n, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        assert isinstance(obj, dict), f"baris {n}: bukan objek"
        assert list(obj.keys()) == keys, f"baris {n}: kunci {list(obj.keys())}"
        assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z", obj["ts"]), f"baris {n}: ts {obj['ts']}"
        assert obj["source"] == want_src, f"baris {n}: source {obj['source']}"
        assert obj["outcome"] in ("success", "failed", "unknown"), f"baris {n}: outcome"
        assert obj["raw_ref"], f"baris {n}: raw_ref kosong"
        assert isinstance(obj["user"], str) and isinstance(obj["src_ip"], str)
        rows.append(obj)
assert len(rows) == want_count, f"jumlah {len(rows)} != {want_count}"
PY
  then ok "$desc"; else bad "$desc"; fi
}

echo "== 0. py_compile =="
if python3 -m py_compile "$BIN"; then ok "kimlogpipe lulus py_compile"; else bad "py_compile"; fi

echo
echo "== 1. senarai peraturan (YAML + fallback) =="
"$BIN" rules >"$TMP/rules-py.out" 2>&1
if [ $? -eq 0 ]; then ok "kimlogpipe rules berjalan"; else bad "kimlogpipe rules"; fi
LAST_OUT="$TMP/rules-py.out"
contains "rules: ssh_bruteforce" "ssh_bruteforce" "$LAST_OUT"
contains "rules: sudo_fail" "sudo_fail" "$LAST_OUT"
contains "rules: audit_exec_watch" "audit_exec_watch" "$LAST_OUT"
contains "rules: aide_change" "aide_change" "$LAST_OUT"
contains "rules: ambang 5" "Ambang: 5 isyarat" "$LAST_OUT"
contains "rules: tetingkap 300" "300 saat" "$LAST_OUT"
contains "rules: senarai pantau" "nmap, nc, curl, wget" "$LAST_OUT"
KIMLOGPIPE_FORCE_MINI_YAML=1 "$BIN" rules >"$TMP/rules-mini.out" 2>&1
if diff -q "$TMP/rules-py.out" "$TMP/rules-mini.out" >/dev/null; then
  ok "fallback parser YAML beri output sama"
else
  bad "fallback parser YAML berbeza"; diff "$TMP/rules-py.out" "$TMP/rules-mini.out" | head
fi

echo
echo "== 2. ingest journald (fixture sebenar) =="
reset_store
run_ok "ingest journald f_sshd.jsonl" "$BIN" ingest --source journald --file "$FIX/f_sshd.jsonl"
contains "journald: 40 peristiwa dihurai" "Peristiwa dihurai : 40" "$LAST_OUT"
contains "journald: 0 baris tidak sah" "Baris tidak sah   : 0" "$LAST_OUT"
check_schema "$STORE/events.jsonl" journald 40 "events.jsonl journald: 40 baris, skema sah"

echo
echo "== 3. dedupe ingest semula =="
run_ok "ingest semula journald" "$BIN" ingest --source journald --file "$FIX/f_sshd.jsonl"
contains "dedupe: 0 baharu" "Peristiwa baharu  : 0" "$LAST_OUT"
contains "dedupe: 40 pendua" "Pendua dilangkau  : 40" "$LAST_OUT"
lines="$(wc -l <"$STORE/events.jsonl" | tr -d ' ')"
if [ "$lines" = "40" ]; then ok "dedupe: events.jsonl kekal 40 baris"; else bad "dedupe: $lines baris"; fi

echo
echo "== 4. ingest auditd (fixture sebenar) =="
run_ok "ingest auditd f_audit.log" "$BIN" ingest --source auditd --file "$FIX/f_audit.log"
contains "auditd: 13 kumpulan peristiwa" "Peristiwa dihurai : 13" "$LAST_OUT"
contains "auditd: jumlah stor 53" "Jumlah dalam stor : 53" "$LAST_OUT"
if python3 - "$STORE/events.jsonl" <<'PY'
import json, sys
src = [json.loads(l)["source"] for l in open(sys.argv[1]) if l.strip()]
assert src.count("auditd") == 13, src.count("auditd")
assert src.count("journald") == 40
PY
then ok "events.jsonl: 13 auditd + 40 journald"; else bad "kiraan sumber auditd"; fi

echo
echo "== 5. detect pada fixture sebenar (kejujuran) =="
run_ok "detect semua peraturan" "$BIN" detect
contains "detect: ssh_bruteforce tiada padanan" "ssh_bruteforce: tiada padanan" "$LAST_OUT"
contains "detect: sudo_fail tidak dapat dinilai" "sudo_fail: tidak dapat dinilai" "$LAST_OUT"
contains "detect: exec_watch tidak dapat dinilai" "audit_exec_watch: tidak dapat dinilai" "$LAST_OUT"
contains "detect: aide_change tidak dapat dinilai" "aide_change: tidak dapat dinilai" "$LAST_OUT"
contains "detect: 0 dapatan (tiada rekaan)" "Jumlah dapatan: 0" "$LAST_OUT"
if python3 - "$STORE/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["findings"] == []
assert len(d["rules"]) == 4
assert {r["rule"] for r in d["rules"]} == {"ssh_bruteforce", "sudo_fail", "audit_exec_watch", "aide_change"}
PY
then ok "findings.json: 0 dapatan, 4 keputusan peraturan"; else bad "findings.json struktur"; fi

echo
echo "== 6. report Bahasa Melayu =="
run_ok "report berjalan" "$BIN" report
contains "report: tajuk" "LAPORAN KIMLOGPIPE" "$LAST_OUT"
contains "report: journald 40" "journald: 40" "$LAST_OUT"
contains "report: auditd 13" "auditd: 13" "$LAST_OUT"
contains "report: kunci teratas" "KUNCI TERATAS" "$LAST_OUT"
contains "report: tiada dapatan jujur" "tiada kunci (tiada dapatan)" "$LAST_OUT"
contains "report: kaveat journald" "Storage=volatile" "$LAST_OUT"
contains "report: kaveat QEMU NAT" "10.0.2.2" "$LAST_OUT"
contains "report: kaveat PerSourcePenalties" "drop connection" "$LAST_OUT"

echo
echo "== 7. ssh_bruteforce + sudo_fail (fixture sintetik, masa kini) =="
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
# 6 isyarat (5 gagal + 1 drop) daripada IP sama dalam 180s
for off, msg in [
    (280, "Failed password for invalid user admin from 203.0.113.9 port 40001 ssh2"),
    (260, "Failed password for invalid user admin from 203.0.113.9 port 40002 ssh2"),
    (240, "Failed password for invalid user admin from 203.0.113.9 port 40003 ssh2"),
    (220, "Failed password for invalid user admin from 203.0.113.9 port 40004 ssh2"),
    (200, "Invalid user oracle from 203.0.113.9 port 40005"),
    (100, "drop connection #0 from 203.0.113.9 port 40006"),
]:
    add(off, msg)
# 3 kegagalan (bawah ambang)
for off in (250, 230, 210):
    add(off, f"Failed password for root from 198.51.100.7 port 5000{off} ssh2")
# 5 kegagalan tetapi tersebar 390s (tiada 5 dalam 300s)
for off in (390, 290, 190, 90, 0):
    add(off, f"Failed password for root from 192.0.2.55 port 6000{off} ssh2")
# kegagalan sudo
add(50, "pam_unix(sudo:auth): authentication failure; logname= uid=0 euid=0 "
        "tty=/dev/pts/0 ruser= user=root", "sudo")
with open(path, "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
run_ok "ingest sintetik ssh/sudo" "$BIN" ingest --source journald --file "$TMP/ssh.jsonl"
run_ok "detect sintetik ssh/sudo" "$BIN" detect
contains "bruteforce: 1 dapatan" "ssh_bruteforce: 1 dapatan" "$LAST_OUT"
contains "bruteforce: kunci 203.0.113.9" "kunci=203.0.113.9 kiraan=6" "$LAST_OUT"
contains "bruteforce: ambang dipetik" "300 saat" "$LAST_OUT"
not_contains "bruteforce: IP bawah ambang tidak dilaporkan" "198.51.100.7" "$LAST_OUT"
not_contains "bruteforce: IP tersebar tidak dilaporkan" "192.0.2.55" "$LAST_OUT"
contains "sudo_fail: 1 dapatan" "sudo_fail: 1 dapatan" "$LAST_OUT"
contains "sudo_fail: kunci root" "kunci=root kiraan=1" "$LAST_OUT"
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
assert f["summary_bm"].startswith("6 isyarat")
PY
then ok "findings.json: bruteforce 6 isyarat + 6 bukti"; else bad "findings bruteforce"; fi

echo
echo "== 8. --since =="
run_ok "detect --since 10m" "$BIN" detect --since 10m
contains "--since 10m: masih ada dapatan" "ssh_bruteforce: 1 dapatan" "$LAST_OUT"
run_ok "detect --since 0s" "$BIN" detect --since 0s
contains "--since 0s: tiada peristiwa" "tiada peristiwa dalam stor/tetingkap" "$LAST_OUT"

echo
echo "== 9. report dengan dapatan + kunci teratas =="
run_ok "detect semula tanpa --since" "$BIN" detect
run_ok "report selepas dapatan" "$BIN" report
contains "report: dapatan bruteforce" "ssh_bruteforce [high]: 1 dapatan" "$LAST_OUT"
contains "report: kunci teratas 203.0.113.9" "203.0.113.9 (6 peristiwa" "$LAST_OUT"

echo
echo "== 10. audit_exec_watch + sudo (auditd sintetik) =="
reset_store
NOW="$(date +%s)"
{
  echo "type=SYSCALL msg=audit($NOW.001:9001): arch=c000003e syscall=59 success=yes exit=0 a0=55d0 a1=55e0 a2=55f0 a3=0 items=2 ppid=1000 pid=1001 auid=1000 uid=1000 gid=1000 euid=1000 suid=1000 fsuid=1000 egid=1000 sgid=1000 fsgid=1000 tty=pts0 ses=3 comm=\"nmap\" exe=\"/usr/bin/nmap\" key=(null)ARCH=x86_64 SYSCALL=execve AUID=\"alice\" UID=\"alice\" GID=\"alice\" EUID=\"alice\" SUID=\"alice\" FSUID=\"alice\" EGID=\"alice\" SGID=\"alice\" FSGID=\"alice\""
  echo "type=EXECVE msg=audit($NOW.001:9001): argc=2 a0=\"nmap\" a1=\"-sV\""
  echo "type=PROCTITLE msg=audit($NOW.001:9001): proctitle=6E6D6170"
  echo "type=SYSCALL msg=audit($NOW.002:9002): arch=c000003e syscall=59 success=yes exit=0 a0=55d0 a1=55e0 a2=55f0 a3=0 items=2 ppid=1000 pid=1002 auid=1000 uid=1000 gid=1000 euid=1000 suid=1000 fsuid=1000 egid=1000 sgid=1000 fsgid=1000 tty=pts0 ses=3 comm=\"ls\" exe=\"/usr/bin/ls\" key=(null)ARCH=x86_64 SYSCALL=execve AUID=\"alice\" UID=\"alice\" GID=\"alice\" EUID=\"alice\" SUID=\"alice\" FSUID=\"alice\" EGID=\"alice\" SGID=\"alice\" FSGID=\"alice\""
  echo "type=USER_AUTH msg=audit($NOW.003:9003): pid=2000 uid=0 auid=1000 ses=3 subj=unconfined msg='op=PAM:authentication grantors=pam_unix acct=\"alice\" exe=\"/usr/bin/sudo\" hostname=10.0.2.2 addr=10.0.2.2 terminal=/dev/pts/0 res=failed'UID=\"root\" AUID=\"alice\""
} >"$TMP/audit.log"
run_ok "ingest auditd sintetik" "$BIN" ingest --source auditd --file "$TMP/audit.log"
contains "auditd sintetik: 3 kumpulan" "Peristiwa dihurai : 3" "$LAST_OUT"
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
then ok "auditd: execve:nmap, execve:ls, sudo_fail dihurai betul"; else bad "auditd sintetik parsing"; fi
run_ok "detect auditd sintetik" "$BIN" detect
contains "exec_watch: 1 dapatan" "audit_exec_watch: 1 dapatan" "$LAST_OUT"
contains "exec_watch: nmap oleh alice" "nmap oleh alice" "$LAST_OUT"
not_contains "exec_watch: ls tidak dilaporkan" "ls oleh" "$LAST_OUT"
contains "sudo_fail auditd: 1 dapatan" "sudo_fail: 1 dapatan" "$LAST_OUT"
if python3 - "$STORE/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = [f for f in d["findings"] if f["rule"] == "audit_exec_watch"]
assert len(ex) == 1 and ex[0]["count"] == 1 and ex[0]["key"] == "alice"
assert 'exe="/usr/bin/nmap"' in ex[0]["evidence"][0]["line"]
PY
then ok "exec_watch: bukti mengandungi exe=/usr/bin/nmap"; else bad "bukti exec_watch"; fi

echo
echo "== 11. aide_change (journald sintetik) =="
reset_store
NOW="$(date +%s)"
{
  echo "{\"__REALTIME_TIMESTAMP\":\"$((NOW * 1000000))\",\"__CURSOR\":\"aide1\",\"_HOSTNAME\":\"arch-uji\",\"SYSLOG_IDENTIFIER\":\"aide\",\"_COMM\":\"aide\",\"MESSAGE\":\"AIDE: added: /etc/passwd\"}"
  echo "{\"__REALTIME_TIMESTAMP\":\"$((NOW * 1000000 + 1000))\",\"__CURSOR\":\"aide2\",\"_HOSTNAME\":\"arch-uji\",\"SYSLOG_IDENTIFIER\":\"aide\",\"_COMM\":\"aide\",\"MESSAGE\":\"AIDE: changed: /etc/shadow\"}"
} >"$TMP/aide.jsonl"
run_ok "ingest aide sintetik" "$BIN" ingest --source journald --file "$TMP/aide.jsonl"
run_ok "detect aide sintetik" "$BIN" detect
contains "aide: 1 dapatan" "aide_change: 1 dapatan" "$LAST_OUT"
contains "aide: kiraan 2" "kiraan=2" "$LAST_OUT"
if python3 - "$STORE/findings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = [f for f in d["findings"] if f["rule"] == "aide_change"]
assert len(a) == 1 and a[0]["count"] == 2 and a[0]["key"] == ""
assert len(a[0]["evidence"]) == 2
PY
then ok "aide: 2 bukti, kunci kosong (tiada pengguna)"; else bad "aide findings"; fi

echo
echo "== 12. pengasingan storan =="
if [ ! -e "$HOME/.local/share/kimlogpipe" ]; then
  ok "tiada storan di HOME sebenar (XDG dihormati)"
else
  bad "storan ditulis ke HOME/.local/share"
fi
case "$(cd "$STORE" && pwd)" in
  "$XDG_DATA_HOME"/*) ok "storan berada di bawah XDG_DATA_HOME" ;;
  *) bad "storan di luar XDG_DATA_HOME" ;;
esac
if find "$ROOT" -maxdepth 1 -name '.kimlogpipe*' -o -maxdepth 1 -name 'events.jsonl' 2>/dev/null | grep -q .; then
  bad "ada fail sisa di akar repo"
else
  ok "tiada fail sisa di akar repo"
fi

echo
echo "=================================================="
echo "KEPUTUSAN: $PASS lulus, $FAIL gagal"
echo "=================================================="
[ "$FAIL" -eq 0 ]
