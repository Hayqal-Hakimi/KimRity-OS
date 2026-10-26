#!/bin/sh
# Tambah repo BlackArch (kunci + mirrorlist + entri pacman.conf).
# Idempotent: selamat dijalankan berulang kali.
set -eu

MIRROR="${BLACKARCH_MIRROR:-https://au.mirrors.cicku.me}"
BASE="$MIRROR/blackarch/blackarch/os/x86_64"
LIST=/etc/pacman.d/blackarch-mirrorlist

say() { printf '[blackarch] %s\n' "$*"; }

command -v pacman >/dev/null 2>&1 || {
  echo "ralat: pacman tiada — jalankan dalam sistem Arch" >&2
  exit 1
}

# 1. mirrorlist
if [ ! -f "$LIST" ]; then
  say "cipta $LIST"
  mkdir -p /etc/pacman.d
  cat > "$LIST" <<'EOF'
Server = https://au.mirrors.cicku.me/blackarch/$repo/os/$arch
Server = https://mirror.serverside.net/blackarch/$repo/os/$arch
Server = https://blackarch.org/blackarch/$repo/os/$arch
EOF
fi

# 2. keyring (nama fail bertukar ikut versi — cari dalam senarai direktori)
if ! pacman -Q blackarch-keyring >/dev/null 2>&1; then
  say "muat turun keyring dari $BASE"
  f=$(curl -fsSL "$BASE/" | grep -oE 'blackarch-keyring-[0-9]+-[0-9]+-any\.pkg\.tar\.zst' | tail -1)
  [ -n "${f:-}" ] || { echo "ralat: keyring tidak dijumpai di $BASE" >&2; exit 1; }
  curl -fsSL -o "/tmp/$f" "$BASE/$f"
  pacman -U --noconfirm "/tmp/$f"
  rm -f "/tmp/$f"
  pacman-key --populate blackarch 2>/dev/null || true
fi

# 3. entri pacman.conf
if ! grep -q '^\[blackarch\]' /etc/pacman.conf; then
  say "tambah [blackarch] ke /etc/pacman.conf"
  printf '\n[blackarch]\nInclude = %s\n' "$LIST" >> /etc/pacman.conf
fi

say "segerak pangkalan data"
pacman -Sy --noconfirm >/dev/null
say "siap"
