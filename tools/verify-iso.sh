#!/bin/bash
# verify-iso.sh — prove the ISO carries the repo, not a stale copy.
#
# Why this exists (build-10 lesson): install.sh copies $SCRIPT_DIR/kimscanning
# into the installed system, so a stale ISO profile silently shipped a 33-entry
# dictionary instead of 41. The only way to see it was to mount the squashfs.
#
# The ISO is read with xorriso + unsquashfs as your own user — no root, no loop
# mount, nothing left behind.
#
# Usage: ./tools/verify-iso.sh [iso]     (default: newest in iso-out/)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ISO="${1:-$(ls -1t iso-out/*.iso 2>/dev/null | head -1)}"
if [ -z "${ISO:-}" ] || [ ! -f "$ISO" ]; then
  echo "ERROR: no ISO found (run build 12 first, or pass a path)" >&2
  exit 1
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/verify-iso.XXXXXX")
# unsquashfs recreates directories with the image's modes, so an extracted
# /root can be 0555 and refuse to give up its children. Make the tree writable
# before removing it; the files belong to this user, only the modes fight back.
trap 'chmod -R u+rwX "$W" 2>/dev/null; rm -rf "$W"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  OK    - $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  - $*"; }
section() { echo; echo "== $* =="; }

SIZE=$(stat -c %s "$ISO")
echo "ISO : $ISO"
echo "Size: $SIZE bytes ($((SIZE / 1024 / 1024)) MiB)"
sha256sum "$ISO" | awk '{print "SHA : " $1}'

if [ "$SIZE" -le 1400000000 ]; then
  pass "size within the 1.4 GB budget"
else
  fail "size above the 1.4 GB budget ($((SIZE / 1024 / 1024)) MiB)"
fi

section "1. extract the live squashfs"
SFS="$W/airootfs.sfs"
if xorriso -osirrox on -indev "$ISO" -extract /arch/x86_64/airootfs.sfs "$SFS" \
    >"$W/xorriso.log" 2>&1 && [ -s "$SFS" ]; then
  pass "squashfs extracted ($(stat -c %s "$SFS") bytes)"
else
  fail "could not extract the squashfs"
  sed -n '1,10p' "$W/xorriso.log" | sed 's/^/      /'
  echo
  echo "  Pass: $PASS  Fail: $FAIL"
  exit 1
fi

section "2. payload equals the repo"
cmp_sfs() {  # cmp_sfs <path inside sfs> <repo path>
  if unsquashfs -cat "$SFS" "$1" 2>/dev/null | cmp -s - "$2"; then
    pass "$1"
  else
    fail "$1 differs from $2"
  fi
}
cmp_sfs /root/install.sh install.sh
cmp_sfs /root/dotfiles/hypr/hyprland.lua dotfiles/hypr/hyprland.lua
cmp_sfs /root/gate/gate.py gate/gate.py
cmp_sfs /root/kimai/kimai kimai/kimai
cmp_sfs /root/kimlogpipe/kimlogpipe kimlogpipe/kimlogpipe
cmp_sfs /root/kimlogpipe/rules.yaml kimlogpipe/rules.yaml
cmp_sfs /root/kimscanning/kimscan kimscanning/kimscan
cmp_sfs /root/kimscanning/rules/en.yaml kimscanning/rules/en.yaml
cmp_sfs /root/systemd/user/kimai.service systemd/user/kimai.service
cmp_sfs /root/systemd/user/kimlogpipe.service systemd/user/kimlogpipe.service
cmp_sfs /root/systemd/system/kimrity-audit.rules systemd/system/kimrity-audit.rules
cmp_sfs /usr/local/bin/kimscan kimscanning/kimscan
cmp_sfs /usr/local/share/kimscanning/rules/en.yaml kimscanning/rules/en.yaml

section "3. permissions that matter"
EXEC_DIR="$W/exec"
mkdir -p "$EXEC_DIR"
if unsquashfs -q -d "$EXEC_DIR/root" "$SFS" usr/local/bin/kimscan \
    >/dev/null 2>&1; then
  MODE=$(stat -c %a "$EXEC_DIR/root/usr/local/bin/kimscan" 2>/dev/null)
  if [ "$MODE" = "755" ]; then
    pass "/usr/local/bin/kimscan is 755 (executable from the live system)"
  else
    fail "/usr/local/bin/kimscan is $MODE, want 755"
  fi
else
  fail "could not extract kimscan for the permission check"
fi

section "4. identity and English-only"
if unsquashfs -cat "$SFS" etc/motd 2>/dev/null | grep -Fq "installer (12 steps"; then
  pass "motd announces the 12-step installer"
else
  fail "motd still advertises the old step count"
fi
if unsquashfs -cat "$SFS" root/install.sh 2>/dev/null | grep -Fq 'HOSTNAME="kimrity"'; then
  pass "installer defaults to hostname kimrity"
else
  fail "installer does not default to hostname kimrity"
fi
BM_HITS=0
for f in root/install.sh root/kimai/kimai root/kimlogpipe/kimlogpipe \
         root/kimscanning/kimscan etc/motd; do
  n=$(unsquashfs -cat "$SFS" "$f" 2>/dev/null \
      | grep -Eoiw 'dan|yang|untuk|tidak|dengan|adalah|boleh|ini|itu' | wc -l)
  BM_HITS=$((BM_HITS + n))
done
if [ "$BM_HITS" -eq 0 ]; then
  pass "no Malay stopwords in the shipped tools or motd"
else
  fail "$BM_HITS Malay stopword(s) in the shipped files"
fi

echo
echo "  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
