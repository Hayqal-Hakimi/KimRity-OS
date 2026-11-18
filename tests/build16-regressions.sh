#!/usr/bin/env bash
# Regression proofs for the Build 16 fixes, run as the desktop user.
# Every check prints PASS/FAIL and a command the reader can repeat.
set -u
REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
T=${T:-${TMPDIR:-/tmp}/kimrity-b16-test}
rm -rf "$T"; mkdir -p "$T"
KP="$REPO/kimlogpipe/kimlogpipe"
KS="$REPO/kimscanning/kimscan"
fail=0
ck() { # ck <name> <condition-result> <detail>
  if [ "$2" = 0 ]; then printf '  PASS  %s\n' "$1"; else printf "  FAIL  %s — %s\n" "$1" "${3:-}"; fail=1; fi
}

echo "=== #1 stderr journalctl dibaca (tiada deadlock) ==="
mkdir -p "$T/bin1"
cat > "$T/bin1/journalctl" <<'EOF'
#!/usr/bin/env bash
head -c 524288 /dev/zero | tr '\0' 'x' >&2
printf '{"__CURSOR":"c1","MESSAGE":"hello","__REALTIME_TIMESTAMP":"1"}\n'
exec sleep 30
EOF
chmod +x "$T/bin1/journalctl"
XDG_DATA_HOME="$T/xd1" PATH="$T/bin1:$PATH" timeout 10 "$KP" follow --source journald --no-kimai >/dev/null 2>&1
n=$(wc -l < "$T/xd1/kimlogpipe/events.jsonl" 2>/dev/null || echo 0)
[ "${n:-0}" -ge 1 ]; ck "512 KiB stderr, event masih masuk (n=$n)" $?

echo "=== #2 ralat follower -> exit bukan-sifar ==="
mkdir -p "$T/bin2"
cat > "$T/bin2/journalctl" <<'EOF'
#!/usr/bin/env bash
echo "Failed to open journal: No such file or directory" >&2
exit 1
EOF
chmod +x "$T/bin2/journalctl"
XDG_DATA_HOME="$T/xd2" PATH="$T/bin2:$PATH" timeout 20 "$KP" follow --source journald --no-kimai >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; ck "keluar rc=$rc (bukan 0, bukan timeout)" $? "rc=$rc"

echo "=== #3 keutamaan Include sshd (drop-in menang) ==="
mkdir -p "$T/fx/etc/ssh/sshd_config.d"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication no\n' > "$T/fx/etc/ssh/sshd_config"
printf 'PasswordAuthentication yes\n' > "$T/fx/etc/ssh/sshd_config.d/50-test.conf"
XDG_DATA_HOME="$T/xd3" KIMSCAN_POSTURE_ROOT="$T/fx" "$KS" posture > "$T/posture.txt" 2>&1
grep -q "sshd:passwordauthentication" "$T/posture.txt"; ck "drop-in 'yes' dilaporkan (tidak lagi tersembunyi)" $? "tidak dijumpai dalam posture"

echo "=== #4 status <nombor> boleh dipakai pada sesi posture ==="
sid=$(ls -1t "$T/xd3/kimscanning/sessions" 2>/dev/null | head -1)
XDG_DATA_HOME="$T/xd3" "$KS" status "$sid" 1 accepted > "$T/status.txt" 2>&1
ck "status $sid 1 accepted (exit 0)" $? "$(tail -1 "$T/status.txt")"

echo "=== #5 artifak 0600 / direktori 0700 ==="
m1=$(stat -c %a "$T/xd3/kimscanning/sessions/$sid/session.json" 2>/dev/null || echo "-")
m2=$(stat -c %a "$T/xd3/kimscanning/sessions/$sid" 2>/dev/null || echo "-")
m3=$(stat -c %a "$T/xd1/kimlogpipe/events.jsonl" 2>/dev/null || echo "-")
[ "$m1" = 600 ] && [ "$m2" = 700 ] && [ "$m3" = 600 ]; ck "session.json=$m1 dir=$m2 events.jsonl=$m3" $?

echo "=== #7 pemalar boleh di-override melalui persekitaran ==="
v=$(KIMLOGPIPE_ROTATE_BYTES=12345 python3 - "$KP" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("k", sys.argv[1])
spec = importlib.util.spec_from_loader("k", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print(m.EVENT_ROTATE_BYTES)
PY
)
[ "$v" = 12345 ]; ck "KIMLOGPIPE_ROTATE_BYTES=12345 -> $v" $?

echo
[ "$fail" = 0 ] && echo "SEMUA LULUS" || echo "ADA KEGAGALAN"
exit "$fail"
