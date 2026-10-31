#!/bin/sh
# Add the BlackArch repo (key + mirrorlist + a pacman.conf entry).
# Idempotent: safe to run repeatedly.
set -eu

MIRROR="${BLACKARCH_MIRROR:-https://au.mirrors.cicku.me}"
BASE="$MIRROR/blackarch/blackarch/os/x86_64"
LIST=/etc/pacman.d/blackarch-mirrorlist

say() { printf '[blackarch] %s\n' "$*"; }

command -v pacman >/dev/null 2>&1 || {
  echo "error: pacman missing — run on an Arch system" >&2
  exit 1
}

# 1. mirrorlist
if [ ! -f "$LIST" ]; then
  say "creating $LIST"
  mkdir -p /etc/pacman.d
  cat > "$LIST" <<'EOF'
Server = https://au.mirrors.cicku.me/blackarch/$repo/os/$arch
Server = https://mirror.serverside.net/blackarch/$repo/os/$arch
Server = https://blackarch.org/blackarch/$repo/os/$arch
EOF
fi

# 2. keyring (the filename changes between versions — find it in the directory listing)
if ! pacman -Q blackarch-keyring >/dev/null 2>&1; then
  say "downloading the keyring from $BASE"
  f=$(curl -fsSL "$BASE/" | grep -oE 'blackarch-keyring-[0-9]+-[0-9]+-any\.pkg\.tar\.zst' | tail -1)
  [ -n "${f:-}" ] || { echo "error: keyring not found at $BASE" >&2; exit 1; }
  curl -fsSL -o "/tmp/$f" "$BASE/$f"
  pacman -U --noconfirm "/tmp/$f"
  rm -f "/tmp/$f"
  pacman-key --populate blackarch 2>/dev/null || true
fi

# 3. pacman.conf entry
if ! grep -q '^\[blackarch\]' /etc/pacman.conf; then
  say "adding [blackarch] to /etc/pacman.conf"
  printf '\n[blackarch]\nInclude = %s\n' "$LIST" >> /etc/pacman.conf
fi

say "syncing the database"
pacman -Sy --noconfirm >/dev/null
say "done"
