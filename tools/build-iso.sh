#!/bin/bash
# build-iso.sh — the one documented way to build the KimRity ISO.
#
# Why this exists: every build so far was typed by hand from shell history, so
# the repo could not tell you (or a future operator) how to reproduce an ISO,
# and it was easy to forget `sync-iso.sh` and ship stale payload (the build-10
# lesson: a 30-Oct rule file inside a 14-Nov ISO).
#
# Usage: ./tools/build-iso.sh [--no-verify]
#   --no-verify   skip tools/verify-iso.sh (build only)
#
# Requires: mkarchiso (package `archiso`), root for mkarchiso, ~8 GiB free in
# /var/tmp for the work directory.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD
WORK=${KIMRITY_WORK:-/var/tmp/kimrity-work}
OUT=${KIMRITY_OUT:-$REPO/iso-out}
VERIFY=1
[ "${1:-}" = "--no-verify" ] && VERIFY=0

need() { command -v "$1" >/dev/null || { echo "[x] missing: $1" >&2; exit 1; }; }
need mkarchiso
need rsync
MKARCHISO=$(command -v mkarchiso)

# mkarchiso must run as root. On this host the passwordless `sudo` grant is
# temporary (polkit), so `sudo` starts asking for a password once it expires and
# a build dies with "sudo: a terminal is required to read the password" — that
# is exactly how the 15 Nov rebuild was lost. Try sudo non-interactively first,
# then polkit (pkexec), which is the real root path here.
as_root() {
  if sudo -n true 2>/dev/null; then
    sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  else
    echo "[x] no non-interactive root: 'sudo -n' failed and pkexec is missing" >&2
    exit 1
  fi
}

# 1. The ISO payload is a COPY of the repo. Never build from a stale copy.
echo "==> sync repo -> ISO profile"
./tools/sync-iso.sh
./tools/sync-iso.sh --check            # exits 1 on drift; must be clean before building

# 2. mkarchiso needs root and a clean work dir.
# Free space is checked on the filesystem that actually holds WORK, instead of a
# hardcoded /var/tmp: KIMRITY_WORK can point anywhere.
work_fs=$(dirname "$WORK")
avail=$(df -BG --output=avail "$work_fs" | tail -1 | tr -dc '0-9')
[ "${avail:-0}" -ge 8 ] || { echo "[x] need >=8 GiB free in $work_fs (have ${avail} GiB)" >&2; exit 1; }
# WORK is owned by root after a build, so it needs the same root path.
as_root rm -rf "$WORK"
mkdir -p "$OUT"

# 3. Build. `-v` so the log is useful when something breaks at 03:00. The log
# directory is a variable: a hardcoded scratch path breaks the build on any other
# machine (the same trap as the `sudo` call, which cost the 15 Nov rebuild).
LOG_DIR=${KIMRITY_LOG_DIR:-${TMPDIR:-/tmp}/kimrity-build}
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=${TMPDIR:-/tmp}
log=$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log
echo "==> mkarchiso (log: $log)"
set +e
as_root "$MKARCHISO" -v -w "$WORK" -o "$OUT" "$REPO/iso" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" -eq 0 ] || { echo "[x] mkarchiso failed ($rc) — see $log" >&2; exit "$rc"; }

iso=$(ls -t "$OUT"/kimrity-*.iso | head -1)
echo "==> built: $iso"
printf '    size:   %s\n' "$(du -h "$iso" | cut -f1)"
printf '    sha256: %s\n' "$(sha256sum "$iso" | cut -d' ' -f1)"

# 4. A built ISO that was never checked is not evidence. Run the 19 static checks.
if [ "$VERIFY" = 1 ]; then
  echo "==> verify-iso.sh"
  ./tools/verify-iso.sh "$iso"
fi

echo "==> done"
