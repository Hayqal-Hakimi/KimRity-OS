#!/usr/bin/env bash
# =============================================================================
# install.sh — minimal Arch + Hyprland installer for the os-security-ai project
#
# Run from an Arch ISO (or any Arch system with arch-install-scripts)
# as root. It DESTROYS the given disk — no default target.
#
#   ./install.sh --disk /dev/vda --hostname arch-uji --user hayqal
#   ./install.sh --disk /dev/vda --dry-run        # print only, no changes
#
# After it finishes: `passwd` (root) and `passwd <user>` — passwords are NEVER
# set by this script.
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------- defaults
HOSTNAME="arch-uji"
USERNAME="hayqal"
USER_UID=1000
TIMEZONE="Asia/Kuala_Lumpur"
LOCALE="en_US.UTF-8"
KEYMAP="us"
ESP_LABEL="ESP"
ROOT_LABEL="arch"
ROOT_SUBVOL="@"
HOME_SUBVOL="@home"
SNAP_SUBVOL="@snapshots"
MOUNT_OPTS="compress=zstd:3"
MOUNTPOINT="/mnt"
LOG="/var/log/install-arch.log"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$SCRIPT_DIR/dotfiles"

DISK=""
DRY=0
ASSUME_YES=0
FORCE=0
EFI=0
LAB=0
FLATPAK=0
AI_PKGS=0

BASE_PKGS=(base linux linux-firmware btrfs-progs snapper snap-pac networkmanager sudo neovim limine efibootmgr openssh)
DESKTOP_PKGS=(hyprland hypridle hyprlock hyprpolkitagent quickshell
              kitty waybar wofi mako cliphist yazi playerctl
              xdg-desktop-portal-hyprland xdg-desktop-portal
              polkit pipewire pipewire-pulse wireplumber mesa
              swaybg ttf-jetbrains-mono-nerd)
TOOL_PKGS=(git btop wl-clipboard grim slurp tcpdump nmap audit firefox iputils inetutils
           python curl unzip gitleaks trivy nikto perl-xml-writer ssh-audit)

# ------------------------------------------------------------------ utilities
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_grn" "$*" "$c_off"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[!] %s%s\n' "$c_yel" "$*" "$c_off"; }
die()  { printf '%s[x] %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

run() {
  printf '+ %s\n' "$*"
  [ "$DRY" = 1 ] && return 0
  "$@"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --disk /dev/XXX [options]

  --disk PATH      (REQUIRED) target disk, e.g. /dev/vda  — it will be ERASED
  --hostname NAME  default: $HOSTNAME
  --user NAME      default: $USERNAME (UID 1000, group wheel)
  --timezone TZ    default: $TIMEZONE
  --dotfiles DIR   default: $DOTFILES_DIR
  --yes            do not ask for typed confirmation
  --force          allow a disk that already has NTFS partitions (Windows)
  --efi            VM: write a Limine NVRAM entry via efibootmgr
  --lab            install the lab profile (BlackArch arsenal, analysis tools)
  --flatpak        install flatpak + Flathub (runtime only, no apps);
                   add apps later with kimrity-flatpak
  --ai             also install heavy AI security tools (needs --lab)
  --dry-run        print commands only, no changes
  -h, --help

Default = lean (package triage rule, 14 Nov): daily tools only + the
Security Gate + kimscan. Analysis tools live in --lab, build tools are
installed on demand, and Flatpak is opt-in.
EOF
}

# ------------------------------------------------------------------ CLI args
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)      DISK="${2:-}"; shift 2 ;;
    --hostname)  HOSTNAME="${2:-}"; shift 2 ;;
    --user)      USERNAME="${2:-}"; shift 2 ;;
    --timezone)  TIMEZONE="${2:-}"; shift 2 ;;
    --dotfiles)  DOTFILES_DIR="${2:-}"; shift 2 ;;
    --yes)       ASSUME_YES=1; shift ;;
    --force)     FORCE=1; shift ;;
    --efi)       EFI=1; shift ;;
    --lab)       LAB=1; shift ;;
    --flatpak)   FLATPAK=1; shift ;;
    --no-arsenal) warn "--no-arsenal is now the default (lab tools are opt-in via --lab)"; shift ;;
    --ai)        AI_PKGS=1; LAB=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

# partition: /dev/vda1 but /dev/nvme0n1p1
part() {
  case "$DISK" in
    *nvme*|*mmcblk*) printf '%sp%s' "$DISK" "$1" ;;
    *)               printf '%s%s' "$DISK" "$1" ;;
  esac
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "tool missing: $1"; }

# ----------------------------------------------------------------- preflight
preflight() {
  step "Preflight"

  [ "$(id -u)" -eq 0 ] || die "must run as root"
  [ -n "$DISK" ] || die "--disk is REQUIRED (no default value — it erases a disk)"

  [ -b "$DISK" ] || die "$DISK is not a block device"
  [ -d "/sys/block/$(basename "$DISK")" ] || die "$DISK is not a whole disk (do not pass a partition)"

  info "target disk : $DISK ($(lsblk -dno SIZE "$DISK" | tr -d ' '))"
  info "hostname    : $HOSTNAME"
  info "user        : $USERNAME (UID $USER_UID)"
  info "timezone    : $TIMEZONE"
  info "dotfiles    : $DOTFILES_DIR"

  # Avoid wiping the disk that is currently holding the ISO
  local iso_src iso_parent
  iso_src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
  if [ -n "$iso_src" ]; then
    iso_parent="$(lsblk -no PKNAME "$iso_src" 2>/dev/null | head -1 || true)"
    [ "$iso_parent" = "$(basename "$DISK")" ] && \
      die "this disk holds the running ISO — pick another disk"
  fi

  # Avoid wiping Windows (project rule: sda must never be touched)
  if lsblk -no FSTYPE "$DISK" 2>/dev/null | grep -qx 'ntfs'; then
    [ "$FORCE" = 1 ] || die "this disk contains NTFS (Windows). Use --force only if you are absolutely sure"
    warn "disk has NTFS — continuing because of --force"
  fi

  # Do not touch a disk whose partitions are still mounted
  if lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -qv '^$'; then
    die "a partition on $DISK is still mounted — unmount it first"
  fi

  if [ ! -d /sys/firmware/efi ]; then
    die "this system is not UEFI (no /sys/firmware/efi) — this script only supports UEFI"
  fi

  local size_gib
  size_gib=$(lsblk -bdno SIZE "$DISK" | awk '{printf "%d", $1/1024/1024/1024}')
  [ "$size_gib" -ge 20 ] || die "disk is too small (${size_gib} GiB) — needs ≥ 20 GiB"

  local c
  for c in sgdisk mkfs.fat mkfs.btrfs pacstrap arch-chroot genfstab blkid; do
    need_cmd "$c"
  done
  [ -d "$DOTFILES_DIR" ] || warn "dotfiles missing: $DOTFILES_DIR — the dotfiles step will be skipped"

  info "all checks passed"
}

confirm() {
  [ "$DRY" = 1 ] && return 0
  [ "$ASSUME_YES" = 1 ] && return 0

  cat <<EOF

$(printf '%s' "$c_red")WARNING: all data on $DISK will be erased.$(printf '%s' "$c_off")
Type YES to continue:
EOF
  local ans; read -r ans
  [ "$ans" = "YES" ] || die "cancelled by the user"
}

# -------------------------------------------------------------------- steps
partition_disk() {
  step "1/11 GPT partition: ${ESP_LABEL} 1 GiB + ${ROOT_LABEL} (rest)"
  run wipefs -a "$DISK"
  run sgdisk --zap-all "$DISK"
  run sgdisk -n "1:0:+1G" -t "1:ef00" -c "1:$ESP_LABEL" "$DISK"
  run sgdisk -n "2:0:0"   -t "2:8300" -c "2:$ROOT_LABEL" "$DISK"
  run udevadm settle

  # wait for partition nodes to appear (kernel/udev, not partprobe)
  if [ "$DRY" = 0 ]; then
    local i
    for i in $(seq 1 20); do
      [ -b "$(part 1)" ] && [ -b "$(part 2)" ] && break
      sleep 0.5
    done
    [ -b "$(part 1)" ] && [ -b "$(part 2)" ] || die "partitions did not appear after partitioning"
  fi
}

format_and_mount() {
  local root="${DISK}"; root="$(part 2)"; local esp; esp="$(part 1)"

  step "2/11 Format: vfat (ESP) + btrfs ($ROOT_LABEL)"
  run mkfs.fat -F 32 -n "$ESP_LABEL" "$esp"
  run mkfs.btrfs -f -L "$ROOT_LABEL" "$root"

  # @snapshots lives at FS_TREE level (sibling of @), NOT nested under @.
  # A rollback replaces @ (rename @ -> @.bak, new -> @); a sibling snapshot DB
  # survives that untouched. Nested under @ it would move with the damaged
  # system (the B0b lesson: mv across subvolumes fails with EXDEV).
  # It is mounted only later — snapper's create-config needs /.snapshots to
  # not exist yet as a mountpoint (ArchWiki: Snapper # Btrfs layout).
  step "3/11 Subvolumes + mounts ($MOUNT_OPTS)"
  run mount "$root" "$MOUNTPOINT"
  run btrfs subvolume create "$MOUNTPOINT/$ROOT_SUBVOL"
  run btrfs subvolume create "$MOUNTPOINT/$HOME_SUBVOL"
  run btrfs subvolume create "$MOUNTPOINT/$SNAP_SUBVOL"
  run umount "$MOUNTPOINT"
  run mount -o "$MOUNT_OPTS,subvol=$ROOT_SUBVOL" "$root" "$MOUNTPOINT"
  run mkdir -p "$MOUNTPOINT/home" "$MOUNTPOINT/boot"
  run mount -o "$MOUNT_OPTS,subvol=$HOME_SUBVOL" "$root" "$MOUNTPOINT/home"
  run mount "$esp" "$MOUNTPOINT/boot"
}

pacstrap_base() {
  step "4/11 pacstrap base packages (${#BASE_PKGS[@]} packages)"

  # No -K here. `pacstrap -K` initialises an EMPTY keyring in the target and
  # implies -G (never copy the host keyring), so package signature checks fail
  # with "required key missing from keyring". The live ISO populates its own
  # keyring at boot via pacman-init.service (shipped in this ISO profile) and
  # pacstrap copies that populated keyring into the new root.
  run pacstrap "$MOUNTPOINT" "${BASE_PKGS[@]}"

  step "5/11 genfstab"
  if [ "$DRY" = 1 ]; then
    printf '[dry] genfstab -U %s >> %s/etc/fstab\n' "$MOUNTPOINT" "$MOUNTPOINT"
  else
    genfstab -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"
    printf '+ genfstab -U %s >> %s/etc/fstab\n' "$MOUNTPOINT" "$MOUNTPOINT"
  fi
}

chroot_configure() {
  local cfile="$MOUNTPOINT/root/chroot-setup.sh"

  step "6/11 Configuration inside the chroot (timezone, locale, hostname, initramfs, user, sudoers)"

  if [ "$DRY" = 1 ]; then
    printf '[dry] write %s and run: arch-chroot %s bash /root/chroot-setup.sh\n' "$cfile" "$MOUNTPOINT"
    return 0
  fi

  cat > "$cfile" <<CHROOT
#!/usr/bin/env bash
set -Eeuo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/^#${LOCALE//./\\.} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf
printf '%s\n' "$HOSTNAME" > /etc/hostname

mkinitcpio -P
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable auditd

# Persistent logs (artifact finding #1: journald is not persistent by default)
mkdir -p /var/log/journal

id -u "$USERNAME" >/dev/null 2>&1 || \
  useradd -m -u $USER_UID -G wheel -s /bin/bash "$USERNAME"

printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c

rm -f /root/chroot-setup.sh
CHROOT

  run chmod +x "$cfile"
  run arch-chroot "$MOUNTPOINT" bash /root/chroot-setup.sh
}

bootloader_limine() {
  local root esp uuid
  root="$(part 2)"; esp="$(part 1)"

  step "7/11 Limine (fallback path + limine.conf)"

  if [ "$DRY" = 1 ]; then
    printf '[dry] cp BOOTX64.EFI -> %s/boot/EFI/BOOT/ ; write limine.conf (UUID from blkid)\n' "$MOUNTPOINT"
    return 0
  fi

  uuid="$(blkid -s UUID -o value "$root")"
  [ -n "$uuid" ] || die "could not get the UUID for $root"

  mkdir -p "$MOUNTPOINT/boot/EFI/BOOT"
  cp "$MOUNTPOINT/usr/share/limine/BOOTX64.EFI" "$MOUNTPOINT/boot/EFI/BOOT/"

  cat > "$MOUNTPOINT/boot/EFI/BOOT/limine.conf" <<CONF
timeout: 2

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=$uuid rw rootflags=subvol=$ROOT_SUBVOL
    module_path: boot():/initramfs-linux.img
CONF

  info "root UUID: $uuid"

  if [ "$EFI" = 1 ]; then
    run efibootmgr --create --disk "$DISK" --part 1 --label "Limine" \
        --loader '\EFI\BOOT\BOOTX64.EFI' --unicode
  else
    info "NVRAM entry skipped (use --efi for VMs); the fallback path is already enough to boot"
  fi
}

install_dotfiles() {
  step "8/11 Dotfiles -> /home/$USERNAME"
  if [ ! -d "$DOTFILES_DIR" ]; then
    warn "dotfiles missing — skipped"; return 0
  fi
  if [ "$DRY" = 1 ]; then
    printf '[dry] cp %s/{hypr,kitty,waybar,quickshell,wofi} -> %s/home/%s/.config/ ; kimrity/workspaces.conf -> ~/.config/kimrity/ ; bash_profile -> ~/.bash_profile\n' \
      "$DOTFILES_DIR" "$MOUNTPOINT" "$USERNAME"
    return 0
  fi

  local home="$MOUNTPOINT/home/$USERNAME"
  install -d -m 755 "$home/.config"
  local d
  for d in hypr kitty waybar quickshell wofi; do
    [ -d "$DOTFILES_DIR/$d" ] || continue
    install -d "$home/.config/$d"
    cp -a "$DOTFILES_DIR/$d/." "$home/.config/$d/"
  done
  # kimrity-ws / workspace-launch / kimrity-icons / shell.qml all read this path
  if [ -f "$DOTFILES_DIR/kimrity/workspaces.conf" ]; then
    install -d -m 755 "$home/.config/kimrity"
    install -m 644 "$DOTFILES_DIR/kimrity/workspaces.conf" "$home/.config/kimrity/workspaces.conf"
  fi
  [ -f "$DOTFILES_DIR/bash_profile" ] && cp -a "$DOTFILES_DIR/bash_profile" "$home/.bash_profile"
  if [ -d "$DOTFILES_DIR/local-bin" ]; then
    install -d -m 755 "$home/.local/bin"
    install -m 755 "$DOTFILES_DIR/local-bin/"* "$home/.local/bin/"
  fi
  if [ -d "$DOTFILES_DIR/kimrity/icons" ]; then
    install -d -m 755 "$home/.local/share/kimrity/icons"
    cp -a "$DOTFILES_DIR/kimrity/icons/." "$home/.local/share/kimrity/icons/"
  fi
  chown -R "$USER_UID:$USER_UID" "$home"
  info "dotfiles copied"
}

install_packages() {
  step "9/11 Desktop packages (${#DESKTOP_PKGS[@]}) + base tools (${#TOOL_PKGS[@]})"
  run arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "${DESKTOP_PKGS[@]}" "${TOOL_PKGS[@]}"
}

# -----------------------------------------------------------------------------
# Snapshot stack (B0c) — lessons baked in from B0a/B0b (8 Nov, proven in QEMU):
#
#   * snapper + snap-pac are in BASE_PKGS: pacman transactions get pre/post
#     snapshots automatically once the config exists. Hooks failing before
#     that are non-fatal (verified: pacman keeps rc=0, "config does not exist").
#   * create-config must run while /.snapshots does NOT exist as a mountpoint
#     (ArchWiki notes it fails otherwise). It creates a nested .snapshots
#     under @ — we delete it and mount the FS_TREE sibling @snapshots there.
#   * fstab uses a subvol= path (not subvolid), so the snapshot DB mount
#     survives renames of @ during a rollback. ID-anchored fstab (subvolid=<n>)
#     is the fix for already-installed systems (B0b lesson).
#   * Rolling back — the proven operator procedure (B0b):
#       1) snapper --ambit classic rollback N   (the ambit is required)
#       2) boot the RW clone: in limine.conf set
#          rootflags=subvol=@/.snapshots/N/snapshot  (pick a menu entry if
#          the system cannot boot at all)
#       3) merge: btrfs snapshot of that clone to FS_TREE (@new), then rename
#          inside FS_TREE (@ -> @.bak-damaged, @new -> @) and set the default
#          subvolume. NEVER mv content across subvolumes — btrfs says EXDEV.
#       4) with @snapshots as a sibling, no snapshot-DB transplant is needed.
#   * systemd stub subvolumes (var/lib/portables, var/lib/machines) show up as
#     empty stubs inside a snapshot — normal, nothing to do.
# -----------------------------------------------------------------------------
install_snapper_stack() {
  step "10/11 Snapshot stack: snapper configs (root, home) + limits + timers"

  if [ "$DRY" = 1 ]; then
    printf '[dry] chroot: snapper create-config / (root) + /home (home)\n'
    printf '[dry] chroot: delete nested /.snapshots created by create-config\n'
    printf '[dry] append fstab entry for %s + mount it + chmod 750\n' "$SNAP_SUBVOL"
    printf '[dry] per-config limits (root: 5h/7d/2w/1m, home: 5h/7d/0w/10m) + number 50\n'
    printf '[dry] enable snapper-timeline.timer snapper-cleanup.timer\n'
    return 0
  fi

  # --no-dbus works without a running dbus inside the chroot; retry without
  # the flag as a safety net for older snapper builds.
  _snapper_chroot() {
    local cmd
    if run arch-chroot "$MOUNTPOINT" snapper --no-dbus "$@"; then
      return 0
    fi
    warn "snapper --no-dbus failed, retrying plain"
    run arch-chroot "$MOUNTPOINT" snapper "$@"
  }

  _snapper_chroot -c root create-config /
  _snapper_chroot -c home create-config /home

  # Limits (mirrors the values proven in the QEMU guest, B0a)
  _snapper_chroot -c root set-config \
    NUMBER_LIMIT=50 NUMBER_LIMIT_IMPORTANT=10 \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=2 TIMELINE_LIMIT_MONTHLY=1 \
    TIMELINE_LIMIT_QUARTERLY=0 TIMELINE_LIMIT_YEARLY=10
  _snapper_chroot -c home set-config \
    NUMBER_LIMIT=50 NUMBER_LIMIT_IMPORTANT=10 \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 \
    TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=10 \
    TIMELINE_LIMIT_QUARTERLY=0 TIMELINE_LIMIT_YEARLY=10

  # ArchWiki procedure: create-config made a NESTED /.snapshots under @;
  # delete it, then mount the sibling @snapshots at the same path by fstab.
  # Deleting the subvolume removes its directory entry too -> recreate the
  # mountpoint before mounting (found in the build-10 fresh install, 14 Nov).
  run btrfs subvolume delete "$MOUNTPOINT/.snapshots"
  run mkdir -p "$MOUNTPOINT/.snapshots"

  local uuid
  uuid="$(blkid -s UUID -o value "$(part 2)")"

  {
    printf '\n# snapshot DB mount (B0c): sibling subvol, path-anchored so it\n'
    printf '# survives renames of @ during rollback\n'
    printf 'UUID=%s\t/.snapshots\tbtrfs\trw,relatime,%s,subvol=/%s\t0 0\n' \
      "$uuid" "$MOUNT_OPTS" "$SNAP_SUBVOL"
  } >> "$MOUNTPOINT/etc/fstab"
  printf '+ fstab: /.snapshots -> %s (%s)\n' "$SNAP_SUBVOL" "$uuid"

  run mount -o "$MOUNT_OPTS,subvol=$SNAP_SUBVOL" "$(part 2)" "$MOUNTPOINT/.snapshots"
  run chmod 750 "$MOUNTPOINT/.snapshots"

  run arch-chroot "$MOUNTPOINT" systemctl enable snapper-timeline.timer snapper-cleanup.timer

  info "snapshot stack ready (@snapshots sibling, timers on)"
}

install_gate_tools() {
  # ALWAYS installed — the 8 Nov lesson: the default build must carry the
  # gate + kimscan + their engines (repo scans are the daily use case).
  # Engines: gitleaks/trivy/nikto/ssh-audit come from TOOL_PKGS (pacman).
  # semgrep is not in the Arch repos -> venv; nuclei -> pinned binary.
  step "11/11 Security Gate + kimscan (always): engines + semgrep venv + nuclei"

  if [ "$DRY" = 1 ]; then
    printf '[dry] gate.py + kimscan + en.yaml -> /usr/local/bin + /usr/local/share/kimscanning\n'
    printf '[dry] python -m venv /opt/semgrep-venv + pip install semgrep + symlink /usr/local/bin/semgrep\n'
    printf '[dry] nuclei pinned binary (v3.11.1) -> /usr/local/bin/nuclei (best effort)\n'
    printf '[dry] gitleaks/trivy/nikto/ssh-audit arrive via TOOL_PKGS (step 9)\n'
    return 0
  fi

  install -Dm755 "$SCRIPT_DIR/gate/gate.py" "$MOUNTPOINT/usr/local/bin/kimrity-gate"
  install -Dm644 "$SCRIPT_DIR/gate/README.md" "$MOUNTPOINT/usr/share/doc/kimrity/gate.md"
  # KimScanning engine: kimscan CLI reads rules/en.yaml (English, no AI).
  install -Dm755 "$SCRIPT_DIR/kimscanning/kimscan" "$MOUNTPOINT/usr/local/bin/kimscan"
  install -Dm644 "$SCRIPT_DIR/kimscanning/rules/en.yaml" "$MOUNTPOINT/usr/local/share/kimscanning/rules/en.yaml"

  # semgrep: not packaged by Arch — venv keeps it away from system python.
  # Proven working on Python 3.14 during the A4 test (8 Nov).
  run arch-chroot "$MOUNTPOINT" python -m venv /opt/semgrep-venv
  run arch-chroot "$MOUNTPOINT" /opt/semgrep-venv/bin/pip install --no-cache-dir semgrep
  run arch-chroot "$MOUNTPOINT" ln -sf /opt/semgrep-venv/bin/semgrep /usr/local/bin/semgrep

  # nuclei: not packaged by Arch either — pinned release binary, best effort.
  # Daily repo scans do not need it; web scans report the missing tool clearly.
  # NOTE: arch-chroot mounts a FRESH tmpfs on /tmp per invocation (build-10
  # lesson, 14 Nov), so the archive must live in /var/tmp to survive the
  # curl -> unzip handoff.
  if arch-chroot "$MOUNTPOINT" sh -c \
      'curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors -o /var/tmp/nuclei.zip https://github.com/projectdiscovery/nuclei/releases/download/v3.11.1/nuclei_3.11.1_linux_amd64.zip'; then
    if arch-chroot "$MOUNTPOINT" sh -c 'unzip -o /var/tmp/nuclei.zip -d /usr/local/bin/ nuclei'; then
      arch-chroot "$MOUNTPOINT" chmod +x /usr/local/bin/nuclei || true
      info "nuclei installed (pinned v3.11.1)"
    else
      warn "nuclei archive could not be unpacked — install it later (web scans flag it)"
    fi
    arch-chroot "$MOUNTPOINT" rm -f /var/tmp/nuclei.zip || true
  else
    warn "nuclei download failed — install it later (web scans will flag the missing tool)"
  fi
}

install_lab() {
  # Lab profile is OPT-IN (package triage rule, 14 Nov): analysis-only tools
  # (metasploit, ghidra, burpsuite, autopsy, yara, ...) never ship by default.
  if [ "$LAB" = 0 ]; then
    info "lab profile skipped (default lean — enable with --lab)"
    return 0
  fi

  step "Lab profile (--lab): BlackArch arsenal + optional AI tools"
  local list="$SCRIPT_DIR/tools/arsenal.list"
  local ai_list="$SCRIPT_DIR/tools/arsenal-ai.list"
  [ -f "$list" ] || { warn "tools/arsenal.list missing — skipped"; return 0; }

  local pkgs=() line
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    pkgs+=("$line")
  done < "$list"

  if [ "$DRY" = 1 ]; then
    printf '[dry] setup-blackarch inside the chroot -> pacman -S %s lab packages\n' "${#pkgs[@]}"
    [ "$AI_PKGS" = 1 ] && printf '[dry] + blackarch-ai group (%s packages)\n' \
      "$(grep -vcE '^\s*(#|$)' "$ai_list" 2>/dev/null || echo '?')"
    return 0
  fi

  install -Dm755 "$SCRIPT_DIR/tools/setup-blackarch.sh" "$MOUNTPOINT/root/setup-blackarch.sh"
  run arch-chroot "$MOUNTPOINT" sh /root/setup-blackarch.sh

  run arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "${pkgs[@]}"

  if [ "$AI_PKGS" = 1 ] && [ -f "$ai_list" ]; then
    local ai=() aline
    while IFS= read -r aline; do
      case "$aline" in ''|\#*) continue ;; esac
      ai+=("$aline")
    done < "$ai_list"
    run arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "${ai[@]}"
  fi
  rm -f "$MOUNTPOINT/root/setup-blackarch.sh"
  info "lab (${#pkgs[@]} packages) installed"
}

install_flatpak_tools() {
  # Flatpak is OPT-IN (decision 14 Nov): no runtime, no Flathub by default.
  # The kimrity-flatpak helper (dotfiles/local-bin) adds apps on demand.
  if [ "$FLATPAK" = 0 ]; then
    info "flatpak skipped (opt-in: --flatpak, or later 'sudo pacman -S flatpak' + kimrity-flatpak add <app>')"
    return 0
  fi

  step "Flatpak opt-in (--flatpak): runtime + Flathub, no apps"
  if [ "$DRY" = 1 ]; then
    printf '[dry] pacman -S flatpak; flatpak remote-add flathub (apps later via kimrity-flatpak)\n'
    return 0
  fi
  run arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm flatpak
  run arch-chroot "$MOUNTPOINT" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  info "flatpak ready — add apps with: kimrity-flatpak add com.discordapp.Discord md.obsidian.Obsidian"
}

finish() {
  # Keep the installed footprint inside the 1B budget (<=5 GB): pacman's
  # package cache is ~1.2 GB after a full install and is not needed at runtime.
  # NOTE: `pacman -Scc --noconfirm` answers the DEFAULT (N) to "remove ALL
  # files from cache?" and cleans nothing (build-10 lesson, 14 Nov) -> feed y.
  step "Cleanup: pacman cache (keeps the installed footprint lean)"
  run arch-chroot "$MOUNTPOINT" sh -c 'yes | pacman -Scc'

  step "Done"
  cat <<EOF

System installed to $DISK. What is LEFT (manual, on purpose):

  1. Set the passwords (this script does not touch them):
       arch-chroot $MOUNTPOINT passwd
       arch-chroot $MOUNTPOINT passwd $USERNAME

  2. Optional add-ons (opt-in, by design):
       arch-chroot $MOUNTPOINT pacman -S base-devel        # build AUR packages
       kimrity-flatpak add com.discordapp.Discord         # daily GUI apps
       # lab tools: re-run install.sh with --lab (or install the packages now)

  3. Leave the ISO and boot from the disk:
       umount -R $MOUNTPOINT && reboot

  4. Log in as $USERNAME — Hyprland starts on its own.
EOF
}

# ---------------------------------------------------------------------- main
main() {
  if [ "$DRY" = 0 ]; then
    mkdir -p "$(dirname "$LOG")"
    exec > >(tee -a "$LOG") 2>&1
  fi

  preflight
  confirm

  partition_disk
  format_and_mount
  pacstrap_base
  chroot_configure
  bootloader_limine
  install_dotfiles
  install_packages
  install_snapper_stack
  install_gate_tools
  install_lab
  install_flatpak_tools
  finish
}

main "$@"
