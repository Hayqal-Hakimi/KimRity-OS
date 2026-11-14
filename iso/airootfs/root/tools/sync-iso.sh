#!/bin/bash
# sync-iso.sh — one-way sync: repo -> ISO profile.
#
# Why this exists (build-10 lesson, 14 Nov): the ISO profile carried a stale
# copy of kimscanning/rules/en.yaml from 30 Oct. install.sh copies
# $SCRIPT_DIR/kimscanning, so every install silently shipped the old
# dictionary (33 entries instead of 41). verify_iso.sh caught it only after a
# 7-minute rebuild. Run this before EVERY mkarchiso build.
#
# Usage: ./tools/sync-iso.sh [--check]
#   (no flag)  copy repo files into iso/airootfs
#   --check    report drift only, change nothing (exit 1 if drift exists)
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE=iso/airootfs
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

drift=0
copy() {  # copy <src> <dst-dir-or-file>
  local src="$1" dst="$2"
  if [ "$CHECK" = 1 ]; then
    if [ -d "$src" ]; then
      diff -rq "$src" "$dst" >/dev/null 2>&1 || { echo "DRIFT: $src -> $dst"; drift=1; }
    else
      cmp -s "$src" "$dst" || { echo "DRIFT: $src -> $dst"; drift=1; }
    fi
  else
    if [ -d "$src" ]; then
      mkdir -p "$dst"
      rsync -a --delete "$src"/ "$dst"/
    else
      mkdir -p "$(dirname "$dst")"
      install -Dm"$(stat -c %a "$src")" "$src" "$dst"
    fi
  fi
}

# installer + payload that the live ISO hands to install.sh
copy install.sh                      "$PROFILE/root/install.sh"
copy dotfiles                        "$PROFILE/root/dotfiles"
copy gate                            "$PROFILE/root/gate"
copy tools                           "$PROFILE/root/tools"
copy hardening                       "$PROFILE/root/hardening"
copy kimscanning                     "$PROFILE/root/kimscanning"
copy kimai                           "$PROFILE/root/kimai"
copy kimlogpipe                      "$PROFILE/root/kimlogpipe"
copy systemd                         "$PROFILE/root/systemd"

# what the live environment itself runs
copy kimscanning/kimscan             "$PROFILE/usr/local/bin/kimscan"
copy kimscanning/rules/en.yaml       "$PROFILE/usr/local/share/kimscanning/rules/en.yaml"

if [ "$CHECK" = 1 ]; then
  if [ "$drift" = 0 ]; then echo "OK: ISO profile == repo"; else echo "DRIFT found — run ./tools/sync-iso.sh"; exit 1; fi
else
  echo "synced: repo -> $PROFILE"
fi
