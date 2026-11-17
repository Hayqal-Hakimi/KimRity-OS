#!/usr/bin/env bash
# vm-on-vt.sh — run the KimRity test VM on a spare virtual terminal.
#
# Why: while the VM runs in a window on Omarchy, the host compositor (Hyprland)
# sees every key first and runs its own bindings. SUPER+Q is "Close window" in
# Omarchy (/usr/share/omarchy/default/hypr/bindings/tiling.lua), so it closes
# the VM window instead of reaching the guest. QEMU cannot ask the host to
# stand down: its UI toolkits here (GTK3, SDL2) do not implement
# zwp_keyboard_shortcuts_inhibit_v1 — only GTK4/SDL3 do.
#
# On a bare VT there is no compositor, so keys go straight to QEMU and the
# guest gets the real bindings (SUPER+W, SUPER+SHIFT+K, ...). Nothing in
# Omarchy's or KimRity's keybind configuration is changed.
#
# Usage:  tools/vm-on-vt.sh <iso> <disk.img> [vt] [mem_mb]
# Env:    VM_VT VM_MEM_MB VM_SSH_PORT VM_CPUS VM_SOCK VM_OVMF_VARS VM_OVMF_CODE
#         VM_RUN_DIR (scratch: monitor socket + OVMF vars copy)
# Exit:   Ctrl+Alt+F1/F2 returns to the desktop (Hyprland keeps running).
set -euo pipefail

ISO=${1:?usage: vm-on-vt.sh <iso> <disk.img> [vt] [mem_mb]}
DISK=${2:?usage: vm-on-vt.sh <iso> <disk.img> [vt] [mem_mb]}
# Overridable per machine (positional args win, env is the fallback):
# VM_VT, VM_MEM_MB, VM_SSH_PORT, VM_CPUS, VM_SOCK, VM_OVMF_VARS, VM_OVMF_CODE.
VT=${3:-${VM_VT:-8}}
MEM=${4:-${VM_MEM_MB:-1792}}
SSH_PORT=${VM_SSH_PORT:-2223}
CPUS=${VM_CPUS:-2}
VM_RUN_DIR=${VM_RUN_DIR:-${TMPDIR:-/tmp}/kimrity-vt}
mkdir -p "$VM_RUN_DIR"
SOCK=${VM_SOCK:-$VM_RUN_DIR/mon-vt.sock}
OVMF_VARS=${VM_OVMF_VARS:-$VM_RUN_DIR/OVMF_VARS.fd}
OVMF_CODE=${VM_OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}

[[ -f $ISO ]] || { echo "no such ISO: $ISO" >&2; exit 1; }
[[ -f $DISK ]] || { echo "no such disk: $DISK" >&2; exit 1; }
# OVMF_VARS must exist (a copy of OVMF_VARS.4m.fd) or QEMU starts with no NVRAM.
[[ -f $OVMF_VARS ]] || {
  echo "missing OVMF vars store: $OVMF_VARS" >&2
  echo "  create it once:  cp /usr/share/edk2/x64/OVMF_VARS.4m.fd \"$OVMF_VARS\"" >&2
  exit 1
}

# The VM needs DRM master, which the desktop holds until we switch VT. openvt
# asks logind to switch, then runs QEMU on that terminal; SDL2's kmsdrm driver
# draws straight to the framebuffer with no compositor in between.
# Root path: `sudo -n` when the temporary grant is active, otherwise pkexec
# (hardcoding `sudo` is how the 15 Nov ISO build died).
if sudo -n true 2>/dev/null; then
  ROOT=(sudo)
elif command -v pkexec >/dev/null 2>&1; then
  ROOT=(pkexec)
else
  echo "[x] no non-interactive root: 'sudo -n' failed and pkexec is missing" >&2
  exit 1
fi
rm -f "$SOCK"
exec "${ROOT[@]}" openvt -s -w -c "$VT" -- \
  env SDL_VIDEODRIVER=kmsdrm \
  qemu-system-x86_64 -machine q35 -accel kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OVMF_VARS" \
    -cdrom "$ISO" \
    -drive file="$DISK",if=virtio,format=raw \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -display sdl \
    -monitor "unix:$SOCK,server=on,wait=off"
