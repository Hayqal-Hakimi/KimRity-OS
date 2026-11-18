#!/usr/bin/env bash
# qemu-install-test.sh — repeatable "install KimRity from the live ISO" test.
#
# Why it lives in the repo: Phase 1 is only finished when the install can be
# REPEATED, and until now this was an ad-hoc script in /var/tmp that nobody
# else could run. It boots the ISO in QEMU on a blank disk, drives the live
# shell through the QEMU monitor (sendkey), waits for the installer to reach
# 12/12, sets a known test password, injects an SSH key, powers off, and then
# can boot the installed disk and prove SSH comes up.
#
# Requires: qemu-system-x86_64, edk2-ovmf (OVMF_*.4m.fd), socat, tesseract,
#           imagemagick (magick), python3, curl. Nothing runs as root.
#
# Optional: a local pip wheelhouse (WHEELS_DIR) served over http for the
#           semgrep install; without it the guest downloads from PyPI.
#
# Why: Phase 1 needs proof that the installer works from a cold, blank disk and
# that the installed system survives a reboot. Doing that by hand costs ~10 min
# of babysitting plus OCR guesswork, and it was done from a different ad-hoc
# script every time. This script owns the whole cycle so the test is repeatable.
#
#   ./tools/qemu-install-test.sh install   # blank disk -> ISO -> install.sh -> 12/12 -> poweroff
#   ./tools/qemu-install-test.sh boot      # same disk, no ISO -> boot the installed system
#   ./tools/qemu-install-test.sh stop      # power the VM off
#
# Env overrides: BASE (scratch dir), ISO, DISK, MON, SER, SSH_PORT, WHEELS_PORT,
#                WHEELS_DIR, VM_MEM_MB, VM_CPUS, DISK_SIZE, TARGET_DISK (guest block device),
#                TEST_USER, TEST_PASS.
# Nothing is hardcoded to one machine: the ISO defaults to the newest build in
# this repo's iso-out/, and BASE defaults to a temp directory.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BASE=${BASE:-${TMPDIR:-/tmp}/kimrity-test}
mkdir -p "$BASE"
ISO=${ISO:-$(ls -1t "$REPO"/iso-out/kimrity-*.iso 2>/dev/null | head -1)}
DISK=${DISK:-$BASE/testdisk.img}
DISK_SIZE=${DISK_SIZE:-24G}
MON=${MON:-$BASE/vm.sock}
SER=${SER:-$BASE/vm-serial.log}
SSH_PORT=${SSH_PORT:-2223}
VM_MEM_MB=${VM_MEM_MB:-1792}
VM_CPUS=${VM_CPUS:-2}
OVMF_CODE=${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}
WHEELS_PORT=${WHEELS_PORT:-8000}
WHEELS_DIR=${WHEELS_DIR:-$BASE/wheels}
# Guest-side values. TARGET_DISK is the VM's virtio disk (never a host disk);
# TEST_USER must match install.sh's --user (default there is the same name) and
# TEST_PASS only exists so sudo + hyprlock can be exercised after the boot.
TARGET_DISK=${TARGET_DISK:-/dev/vda}
TEST_USER=${TEST_USER:-hayqal}
TEST_PASS=${TEST_PASS:-kimritytest}
MODE=${1:-install}

say() { printf '\033[36m== %s\033[0m\n' "$*"; }

# A throwaway key so the installed system can be reached over SSH. Generated
# once, kept in $BASE so a boot test after the install works without setup.
ensure_key() {
  [ -f "$BASE/vmkey" ] && return 0
  ssh-keygen -q -t ed25519 -N '' -C 'kimrity-qemu-test' -f "$BASE/vmkey" || die "ssh-keygen failed"
  say "generated test key: $BASE/vmkey"
}
die() { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

mon() { printf '%s\n' "$*" | socat - UNIX-CONNECT:"$MON" >/dev/null 2>&1; }

# screen text, retried: OCR occasionally returns nothing on a half-drawn frame
screen() {
  local i out
  for i in 1 2 3 4 5; do
    mon "screendump $BASE/_scr.ppm"
    magick "$BASE/_scr.ppm" -colorspace Gray -resize 140% "$BASE/_scr.png" 2>/dev/null
    out=$(tesseract "$BASE/_scr.png" - --psm 6 2>/dev/null)
    [ -n "$out" ] || out=$(tesseract "$BASE/_scr.png" - 2>/dev/null)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 2
  done
  return 1
}

# wait_screen <regex> <timeout_s> [consecutive]
wait_screen() {
  # NOTE: each name is declared on its own line. `local a=$1 t=${2:-300}
  # end=$(( $(date +%s) + t ))` fails with `t: unbound variable` under `set -u`:
  # bash declares every name in the `local` command first, so `t` is still unset
  # when the arithmetic is expanded.
  local pat=$1
  local t=${2:-300} need=${3:-2} hits=0
  local end=$(( $(date +%s) + t ))
  while (( $(date +%s) < end )); do
    if screen | grep -qiE -- "$pat"; then
      hits=$((hits+1)); (( hits >= need )) && { say "screen matches: $pat"; return 0; }
    else hits=0; fi
    sleep 4
  done
  say "TIMEOUT waiting for: $pat"; return 1
}

type_line() {  # type_line <text> ; a file path is read as @file
  # The typist ships in the repo (tools/qemu-type.py) so this test does not
  # depend on whatever helper happened to sit in the operator's scratch dir.
  MON="$MON" python3 "$REPO/tools/qemu-type.py" "$1" 0.04 || die "typing failed"
  mon "sendkey ret"
}

qemu_start() {  # $1 = with-iso | disk-only
  local with_iso=$1
  [ -f "$OVMF_VARS" ] || die "missing OVMF vars template: $OVMF_VARS (package edk2-ovmf)"
  cp -f "$OVMF_VARS" "$BASE/OVMF_VARS.fd"
  local args=(-machine q35 -accel kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEM_MB"
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
    -drive if=pflash,format=raw,file="$BASE/OVMF_VARS.fd"
    -drive file="$DISK",if=virtio,format=raw
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -display none -monitor "unix:$MON,server=on,wait=off"
    -serial "file:$SER" -daemonize)
  [ "$with_iso" = with-iso ] && args+=(-cdrom "$ISO")
  rm -f "$MON" "$SER"
  qemu-system-x86_64 "${args[@]}" || die "qemu failed to start"
}

case "$MODE" in
install)
  ensure_key
  rm -f "$DISK"; truncate -s "$DISK_SIZE" "$DISK"
  say "blank disk: $DISK ($DISK_SIZE)"

  # local wheelhouse: offline pip needs a reachable index, and plain http is not
  # "trusted" by pip unless we say so (that exact failure aborted the first run)
  if [ -d "$WHEELS_DIR" ]; then
    pkill -f "http.server $WHEELS_PORT" >/dev/null 2>&1
    ( cd "$WHEELS_DIR" && nohup python3 -m http.server "$WHEELS_PORT" --bind 127.0.0.1 \
        >"$BASE/wheels-http.log" 2>&1 & )
    sleep 1
    curl -sf -o /dev/null "http://127.0.0.1:$WHEELS_PORT/" || die "wheelhouse server not up"
    say "wheelhouse served on 127.0.0.1:$WHEELS_PORT ($(ls "$WHEELS_DIR"/*.whl 2>/dev/null | wc -l) wheels)"
  fi

  say "starting VM with live ISO (disk: $DISK)"
  qemu_start with-iso
  wait_screen "root@archlinux" 240 3 || die "live shell never appeared"

  say "running the installer"
  type_line "KIMRITY_PIP_FIND_LINKS=http://10.0.2.2:$WHEELS_PORT bash /root/install.sh --disk $TARGET_DISK --yes --efi --no-arsenal --no-password --user $TEST_USER"

  # Wait for the END, not for "12/12": that line scrolls off the screen as the
  # summary is printed, so the old pattern timed out on a finished install
  # (17 Nov — the guest sat at a root prompt with "==> Done" already shown).
  if ! wait_screen "Done|\[x\] step" 1500 1; then
    screen | tail -25; die "installer did not finish (no Done line)"
  fi
  if screen | grep -q '\[x\] step'; then
    say "installer reported a failure:"; screen | grep -A3 '\[x\] step'; die "install failed"
  fi
  wait_screen "Done" 180 2 || { screen | tail -20; die "no Done line"; }

  # --no-password keeps the run scriptable; set a known one here instead, so the
  # guest can be checked for sudo + lock-screen auth after boot.
  say "installer finished; setting a known test password + SSH key"
  type_line "echo '$TEST_USER:$TEST_PASS' | arch-chroot /mnt chpasswd && echo PW_OK"
  type_line "install -d -m 700 -o 1000 -g 1000 /mnt/home/$TEST_USER/.ssh && echo '$(cat "$BASE/vmkey.pub")' > /mnt/home/$TEST_USER/.ssh/authorized_keys && chmod 600 /mnt/home/$TEST_USER/.ssh/authorized_keys && chown 1000:1000 /mnt/home/$TEST_USER/.ssh/authorized_keys"
  type_line "grep -c ssh-ed25519 /mnt/home/$TEST_USER/.ssh/authorized_keys"
  screen | tail -4

  say "unmounting and powering off"
  type_line "umount -R /mnt && poweroff -f"
  sleep 8
  pgrep -f "qemu-system-x86_64.*$DISK" >/dev/null && { say "VM still up, forcing stop"; mon quit; }
  say "install test done"
  ;;
boot)
  [ -f "$DISK" ] || die "no disk at $DISK — run 'install' first"
  pgrep -f "qemu-system-x86_64.*$DISK" >/dev/null && die "a VM already uses $DISK — run '$0 stop' first"
  ensure_key
  say "booting the installed disk (no ISO attached)"
  qemu_start disk-only
  # Do NOT gate on screen text: the installed system autologins on tty1 and
  # Hyprland draws a bar, so "login:" never appears — the old
  # wait_screen "login:|Hyprland|kimrity" timed out on a perfectly healthy boot
  # (15 Nov). SSH is the real readiness signal; the screen is only diagnostic.
  for i in $(seq 1 60); do
    ssh -i "$BASE/vmkey" -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 -o BatchMode=yes "$TEST_USER"@127.0.0.1 true 2>/dev/null \
      && { say "SSH is up after ~$((i * 5))s"; exit 0; }
    sleep 5
  done
  screen | tail -20; die "SSH never came up (5 min)"
  ;;
stop)
  mon quit; sleep 2
  pgrep -af qemu-system-x86_64 | grep -v pgrep | cut -c1-50 || say "VM stopped"
  ;;
*) die "usage: $0 install|boot|stop" ;;
esac
