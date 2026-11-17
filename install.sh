#!/usr/bin/env bash
# =============================================================================
# install.sh — minimal Arch + Hyprland installer for the os-security-ai project
#
# Run from an Arch ISO (or any Arch system with arch-install-scripts)
# as root. It DESTROYS the given disk — no default target.
#
#   ./install.sh --disk /dev/vda --hostname kimrity --user hayqal
#   ./install.sh --disk /dev/vda --dry-run        # print only, no changes
#
# After it finishes: `passwd` (root) and `passwd <user>` — passwords are NEVER
# set by this script.
# =============================================================================
set -Eeuo pipefail

# ----------------------------------------------------------------- defaults
HOSTNAME="kimrity"
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
# noatime: btrfs + snapper touch the tree constantly; atime updates are pure
# write amplification and nothing on this box reads atime. It is part of the
# mount string on purpose — genfstab records the live options, so fstab gets it.
MOUNT_OPTS="compress=zstd:3,noatime"
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
NO_PASSWORD=0

BASE_PKGS=(base linux linux-firmware btrfs-progs snapper snap-pac networkmanager sudo neovim limine efibootmgr openssh zram-generator)
DESKTOP_PKGS=(hyprland hypridle hyprlock hyprpolkitagent quickshell
              kitty waybar wofi mako libnotify cliphist yazi playerctl
              xdg-desktop-portal-hyprland xdg-desktop-portal
              xdg-desktop-portal-gtk    # file dialogs (Firefox upload, yazi)
              polkit pipewire pipewire-pulse wireplumber mesa
              pavucontrol               # audio mixer for pipewire-pulse
              swaybg ttf-jetbrains-mono-nerd
              noto-fonts-emoji)         # no tofu in Firefox/Telegram
TOOL_PKGS=(git btop wl-clipboard grim slurp tcpdump nmap audit firefox iputils inetutils
           python curl unzip gitleaks trivy nikto perl-xml-writer ssh-audit)
# Daily apps (B1) — every user touches these in a normal week:
#   zathura+mupdf  keyboard-first PDF (no GTK4 stack), Vim keys
#   qalculate-gtk  scientific calculator + unit/currency conversion (GTK3 already present)
#   mpv            lean Wayland video player (pulls ffmpeg)
#   telegram       daily messaging; in the repo, so pacman (not Flatpak)
APP_PKGS=(zathura zathura-pdf-mupdf qalculate-gtk mpv telegram-desktop xdg-utils)

# ------------------------------------------------------------------ utilities
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'

# Origin of the current step, for the failure pointer (see on_error below).
CUR_STEP_NUM=""
CUR_STEP_NAME="setup (before the first step)"
# Last command handed to run(), so the pointer can name it: a failure inside
# run() reports "$@" otherwise, which tells the operator nothing.
LAST_CMD=""

step() {
  # Remember where we are: "11/12 Foo: bar" -> number 11, name "Foo: bar".
  case "${1:-}" in
    [0-9]*/[0-9]*) CUR_STEP_NUM="${1%%/*}"; CUR_STEP_NAME="${*#* }" ;;
    *)             CUR_STEP_NUM="";        CUR_STEP_NAME="${*:-setup}" ;;
  esac
  printf '\n%s==> %s%s\n' "$c_grn" "$*" "$c_off"
}
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[!] %s%s\n' "$c_yel" "$*" "$c_off"; }
die()  { printf '%s[x] %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

# Failure pointer (daily-use fix, 15 Nov): a real install takes ~10 minutes, so
# a fatal command must TELL you where it died instead of just stopping. Prints
# the step, the exact command and the log path, then keeps the exit code.
# 16 Nov: every known step also prints the arch-chroot line that repeats it, so
# the operator does not have to reinvent the recovery from scratch.
retry_hint() {
  local m="$MOUNTPOINT" efiflag=""
  if [ "$EFI" = 1 ]; then efiflag=" --efi"; fi
  case "${CUR_STEP_NUM:-}" in
    1|2|3)
      printf '    retry: the disk is half-written — start over from the live ISO:\n'
      printf '           bash /root/install.sh --disk %s --yes%s\n' "$DISK" "$efiflag"
      ;;
    4)  printf '    retry: pacstrap %s %s\n' "$m" "${BASE_PKGS[*]}" ;;
    5)  printf '    retry: genfstab -U %s >> %s/etc/fstab\n' "$m" "$m" ;;
    6)  printf '    retry: arch-chroot %s bash /root/chroot-setup.sh   (kept on failure, safe to re-run)\n' "$m"
        printf '           user only?  arch-chroot %s id -u %s || arch-chroot %s useradd -m -u %s -G wheel -s /bin/bash %s\n' \
          "$m" "$USERNAME" "$m" "$USER_UID" "$USERNAME" ;;
    7)  printf "    retry: arch-chroot %s bash -c 'mkinitcpio -P && ls -l /boot/EFI/BOOT/'   (BOOTX64.EFI + limine.conf)\n" "$m"
        if [ "$EFI" = 1 ]; then
          printf '           arch-chroot %s efibootmgr --create --disk %s --part 1 --label Limine --loader "\\EFI\\BOOT\\BOOTX64.EFI" --unicode\n' "$m" "$DISK"
        fi ;;
    8)  printf '    retry: arch-chroot %s chown -R %s:%s /home/%s\n' "$m" "$USER_UID" "$USER_UID" "$USERNAME" ;;
    9)  printf '    retry: repeat the step-9 command printed above (pacman skips what is already installed)\n' ;;
    10) printf '    retry: arch-chroot %s snapper --no-dbus -c root create-config /\n' "$m"
        printf '           arch-chroot %s systemctl enable snapper-timeline.timer snapper-cleanup.timer\n' "$m" ;;
    11) printf '    retry: arch-chroot %s /opt/semgrep-venv/bin/pip install --no-cache-dir semgrep\n' "$m" ;;
    12) printf "    retry: arch-chroot %s sh -c 'ln -sfn /usr/lib/systemd/user/kimai.service /etc/systemd/user/default.target.wants/kimai.service'\n" "$m"
        printf '           arch-chroot %s systemctl enable auditd\n' "$m" ;;
    *)  printf '    retry: fix the failed command and run it again; for a boot problem see README §9\n' ;;
  esac
}

on_error() {
  local rc="$1" cmd="$2"
  trap - ERR
  # A failure inside run() reports the forwarder, not the command it forwarded.
  if [ "$cmd" = '"$@"' ] && [ -n "$LAST_CMD" ]; then cmd="$LAST_CMD"; fi
  if [ -n "$CUR_STEP_NUM" ]; then
    printf '%s[x] step %s/12 (%s) failed at: %s%s\n' \
      "$c_red" "$CUR_STEP_NUM" "$CUR_STEP_NAME" "$cmd" "$c_off" >&2
  else
    printf '%s[x] step %s failed at: %s%s\n' \
      "$c_red" "$CUR_STEP_NAME" "$cmd" "$c_off" >&2
  fi
  retry_hint >&2
  if [ -f "$LOG" ]; then
    printf '    log: %s\n' "$LOG" >&2
  fi
  exit "$rc"
}
trap 'on_error "$?" "$BASH_COMMAND"' ERR

# pip drops a plain-HTTP --find-links host unless it is trusted explicitly
# (first real install, 16 Nov: http://10.0.2.2:8000 was ignored with "not a
# trusted or secure host", then "No matching distribution found for semgrep").
# Returns the host to trust — scheme, path and port stripped — or nothing.
find_links_trusted_host() {
  local v="${1:-}"
  case "$v" in
    http://*) v="${v#http://}"; v="${v%%/*}"; printf '%s' "${v%%:*}" ;;
    *) ;;
  esac
}

run() {
  printf '+ %s\n' "$*"
  LAST_CMD="$*"
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
  --locale LOCALE  default: $LOCALE (system language, /etc/locale.conf)
  --keymap KM      default: $KEYMAP (console keyboard, /etc/vconsole.conf)
  --dotfiles DIR   default: $DOTFILES_DIR
  --yes            do not ask for typed confirmation
  --no-password    do not prompt for passwords at the end (sudo and the
                   hyprlock lock screen stay unusable until you run passwd)
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
    --locale)    LOCALE="${2:-}"; shift 2 ;;
    --keymap)    KEYMAP="${2:-}"; shift 2 ;;
    --dotfiles)  DOTFILES_DIR="${2:-}"; shift 2 ;;
    --yes)       ASSUME_YES=1; shift ;;
    --no-password) NO_PASSWORD=1; shift ;;
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  # --dry-run only prints, so a host without the Arch tools (sgdisk, mkfs.*,
  # arch-chroot) is still an honest dry run, not a failure.
  [ "${DRY:-0}" = 1 ] && { warn "tool missing: $1 (ignored for --dry-run)"; return 0; }
  die "tool missing: $1"
}

# ----------------------------------------------------------------- preflight
preflight() {
  step "Preflight"

  # --disk is checked BEFORE root: "you forgot the disk" is the useful message,
  # and it must be the same one whether or not the caller is root.
  [ -n "$DISK" ] || die "--disk is REQUIRED (no default value — it erases a disk)"

  # --dry-run writes nothing, so it may be run by a normal user on a host that
  # does not have the target device. Real runs keep every guard untouched.
  if [ "$DRY" = 1 ]; then
    [ "$(id -u)" -eq 0 ] || info "not root — fine for --dry-run (nothing is written)"
  else
    [ "$(id -u)" -eq 0 ] || die "must run as root"
  fi

  local have_disk=0
  [ -b "$DISK" ] && have_disk=1
  if [ "$have_disk" = 0 ]; then
    if [ "$DRY" = 1 ]; then
      warn "$DISK is not a block device on this host — --dry-run: device checks skipped, commands printed only"
    else
      die "$DISK is not a block device"
    fi
  fi

  local size="?"
  [ "$have_disk" = 1 ] && size="$(lsblk -dno SIZE "$DISK" | tr -d ' ')"
  info "target disk : $DISK ($size)"
  info "hostname    : $HOSTNAME"
  info "user        : $USERNAME (UID $USER_UID)"
  info "timezone    : $TIMEZONE"
  info "dotfiles    : $DOTFILES_DIR"

  if [ "$have_disk" = 1 ]; then
    [ -d "/sys/block/$(basename "$DISK")" ] || die "$DISK is not a whole disk (do not pass a partition)"

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
  else
    info "[dry] ISO / NTFS / mounted-partition guards are not evaluated (device absent)"
  fi

  if [ ! -d /sys/firmware/efi ]; then
    die "this system is not UEFI (no /sys/firmware/efi) — this script only supports UEFI"
  fi

  local size_gib
  if [ "$have_disk" = 1 ]; then
    size_gib=$(lsblk -bdno SIZE "$DISK" | awk '{printf "%d", $1/1024/1024/1024}')
    [ "$size_gib" -ge 20 ] || die "disk is too small (${size_gib} GiB) — needs ≥ 20 GiB"
  fi

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
  step "1/12 GPT partition: ${ESP_LABEL} 1 GiB + ${ROOT_LABEL} (rest)"
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

  step "2/12 Format: vfat (ESP) + btrfs ($ROOT_LABEL)"
  run mkfs.fat -F 32 -n "$ESP_LABEL" "$esp"
  run mkfs.btrfs -f -L "$ROOT_LABEL" "$root"

  # @snapshots lives at FS_TREE level (sibling of @), NOT nested under @.
  # A rollback replaces @ (rename @ -> @.bak, new -> @); a sibling snapshot DB
  # survives that untouched. Nested under @ it would move with the damaged
  # system (the B0b lesson: mv across subvolumes fails with EXDEV).
  # It is mounted only later — snapper's create-config needs /.snapshots to
  # not exist yet as a mountpoint (ArchWiki: Snapper # Btrfs layout).
  step "3/12 Subvolumes + mounts ($MOUNT_OPTS)"
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
  step "4/12 pacstrap base packages (${#BASE_PKGS[@]} packages)"

  # No -K here. `pacstrap -K` initialises an EMPTY keyring in the target and
  # implies -G (never copy the host keyring), so package signature checks fail
  # with "required key missing from keyring". The live ISO populates its own
  # keyring at boot via pacman-init.service (shipped in this ISO profile) and
  # pacstrap copies that populated keyring into the new root.
  run pacstrap "$MOUNTPOINT" "${BASE_PKGS[@]}"

  step "5/12 genfstab"
  if [ "$DRY" = 1 ]; then
    printf '[dry] genfstab -U %s >> %s/etc/fstab\n' "$MOUNTPOINT" "$MOUNTPOINT"
  else
    genfstab -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"
    printf '+ genfstab -U %s >> %s/etc/fstab\n' "$MOUNTPOINT" "$MOUNTPOINT"

    # fstab sanity check: a missing /, /home or /boot line only becomes visible
    # as an unbootable disk after the reboot, when the mounts above are gone.
    # Fail here instead, while every mount is still live and fixable.
    local t
    for t in / /home /boot; do
      awk -v t="$t" '$2 == t { f = 1 } END { exit !f }' "$MOUNTPOINT/etc/fstab" \
        || die "fstab has no entry for '$t' — do NOT reboot; check the step-3 mounts"
    done
    # genfstab keeps subvol= and drops subvolid= for btrfs (verified), which is
    # what makes a snapper rollback of @ survivable. Warn if that ever changes.
    if ! awk '$2 == "/" { n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "subvol=/@") got = 1 }
              END { exit !got }' "$MOUNTPOINT/etc/fstab"; then
      warn "fstab root line has no subvol=/@ — boot may use the FS top level; fix before reboot"
    fi
  fi
}

chroot_configure() {
  local cfile="$MOUNTPOINT/root/chroot-setup.sh"

  step "6/12 Configuration inside the chroot (timezone, locale, hostname, initramfs, user, sudoers)"

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

# Units that must come up on the first boot. auditd is enabled in step 12, after
# the audit package exists (step 9): `systemctl enable auditd` here fails with
# "Unit file auditd.service does not exist" and aborts the whole installation.
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable fstrim.timer        # weekly TRIM — keeps SSD/NVMe write speed
systemctl enable systemd-timesyncd   # NTP: correct clock before TLS after boot

# zram: compressed swap in RAM instead of a swap partition. On the 1.7 GB test
# VM and the 7.2 GB host this keeps the desktop alive without touching the disk.
# min(ram/2, 4096) means a big machine does not lose half its memory to swap.
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAM

# Autologin on tty1 only: Hyprland starts from ~/.bash_profile, the same model
# Omarchy uses on this hardware. SSH is unaffected. A greeter can replace this
# once the disk is encrypted; until then a login prompt would suggest a
# protection the unencrypted disk does not provide.
install -d -m 755 /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<CONF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear --autologin $USERNAME %I
CONF

# Persistent logs (artifact finding #1: journald is not persistent by default)
mkdir -p /var/log/journal

id -u "$USERNAME" >/dev/null 2>&1 || \
  useradd -m -u $USER_UID -G wheel -s /bin/bash "$USERNAME"

# KimLogPipe runs as a user service and needs to read journald and the audit
# log. systemd-journal already exists on Arch, so the user is added to it here;
# auditd is pointed at the same group in step 12 (auditd.conf does not exist
# yet — the audit package arrives in step 9).
getent group systemd-journal >/dev/null 2>&1 || groupadd -r systemd-journal
usermod -aG systemd-journal "$USERNAME"

# KimAI + KimLogPipe must be alive without an open terminal (the "anti-cheat"
# model from 26 Oct). enable-linger only writes this marker file.
mkdir -p /var/lib/systemd/linger
touch "/var/lib/systemd/linger/$USERNAME"

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

  step "7/12 Limine (fallback path + limine.conf)"

  if [ "$DRY" = 1 ]; then
    printf '[dry] cp BOOTX64.EFI -> %s/boot/EFI/BOOT/ ; write limine.conf (UUID from blkid)\n' "$MOUNTPOINT"
    return 0
  fi

  uuid="$(blkid -s UUID -o value "$root")"
  [ -n "$uuid" ] || die "could not get the UUID for $root"

  # Name the failure: on a run without --efi this fallback binary is the ONLY
  # way into the system, so a raw `cp: cannot stat` would be the last thing a
  # 10-minute install says before it stops.
  local efi_src="$MOUNTPOINT/usr/share/limine/BOOTX64.EFI"
  [ -f "$efi_src" ] || die "limine EFI binary missing: ${efi_src#"$MOUNTPOINT"} — reinstall it with: arch-chroot $MOUNTPOINT pacman -S limine"

  mkdir -p "$MOUNTPOINT/boot/EFI/BOOT"
  cp "$efi_src" "$MOUNTPOINT/boot/EFI/BOOT/"

  cat > "$MOUNTPOINT/boot/EFI/BOOT/limine.conf" <<CONF
timeout: 2

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=$uuid rw rootflags=subvol=$ROOT_SUBVOL
    module_path: boot():/initramfs-linux.img
CONF

  # Dual-boot: if this ESP already holds Windows, put it in the menu once.
  # boot() is the partition Limine was loaded from, i.e. this same ESP, and it
  # survives a UUID change (limine-entry-tool writes an absolute uuid(...)).
  if [ -f "$MOUNTPOINT/boot/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
    cat >> "$MOUNTPOINT/boot/EFI/BOOT/limine.conf" <<'WINCONF'

/Windows Boot Manager
    protocol: efi
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
WINCONF
    info "Windows found on this ESP: added to the Limine menu"
  else
    info "no Windows on this ESP: single-boot menu"
  fi

  info "root UUID: $uuid"

  if [ "$EFI" = 1 ]; then
    run efibootmgr --create --disk "$DISK" --part 1 --label "Limine" \
        --loader '\EFI\BOOT\BOOTX64.EFI' --unicode
  else
    info "NVRAM entry skipped (use --efi for VMs); the fallback path is already enough to boot"
  fi
}

install_dotfiles() {
  step "8/12 Dotfiles -> /home/$USERNAME"
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
  step "9/12 Desktop (${#DESKTOP_PKGS[@]}) + daily apps (${#APP_PKGS[@]}) + base tools (${#TOOL_PKGS[@]})"
  run arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm \
    "${DESKTOP_PKGS[@]}" "${APP_PKGS[@]}" "${TOOL_PKGS[@]}"
  # Daily-app defaults (B1): PDF -> zathura, video -> mpv, web -> firefox.
  # Written per user so file managers and xdg-open agree with the desktop.
  run arch-chroot "$MOUNTPOINT" runuser -u "$USERNAME" -- \
    env HOME="/home/$USERNAME" xdg-mime default org.pwmt.zathura.desktop application/pdf || true
  run arch-chroot "$MOUNTPOINT" runuser -u "$USERNAME" -- \
    env HOME="/home/$USERNAME" xdg-mime default mpv.desktop video/mp4 video/x-matroska video/webm || true
  run arch-chroot "$MOUNTPOINT" runuser -u "$USERNAME" -- \
    env HOME="/home/$USERNAME" xdg-settings set default-web-browser firefox.desktop || true
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
  step "10/12 Snapshot stack: snapper configs (root, home) + limits + timers"

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
    printf 'UUID=%s\t/.snapshots\tbtrfs\trw,%s,subvol=/%s\t0 0\n' \
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
  step "11/12 Security Gate + kimscan (always): engines + semgrep venv + nuclei"

  # pip args are built before the dry-run return so --dry-run shows the command
  # the real run uses, --trusted-host included.
  local pip_args=(--no-cache-dir --retries 2 --timeout 30 --disable-pip-version-check)
  local find_links="${KIMRITY_PIP_FIND_LINKS:-}" trust_host=""
  if [ -n "$find_links" ]; then
    trust_host="$(find_links_trusted_host "$find_links")"
    pip_args+=(--no-index --find-links "$find_links")
    if [ -n "$trust_host" ]; then pip_args+=(--trusted-host "$trust_host"); fi
  fi

  if [ "$DRY" = 1 ]; then
    printf '[dry] gate.py + kimscan + en.yaml -> /usr/local/bin + /usr/local/share/kimscanning\n'
    printf '[dry] python -m venv /opt/semgrep-venv + pip install semgrep (fail-soft: warn, install continues)\n'
    if [ -n "$find_links" ]; then
      printf '[dry] pip --no-index --find-links %s%s (local wheelhouse only)\n' \
        "$find_links" "${trust_host:+ --trusted-host $trust_host}"
    fi
    printf '[dry] nuclei pinned binary (v3.11.1) -> /usr/local/bin/nuclei (best effort)\n'
    printf '[dry] gitleaks/trivy/nikto/ssh-audit arrive via TOOL_PKGS (step 9)\n'
    return 0
  fi

  install -Dm755 "$SCRIPT_DIR/gate/gate.py" "$MOUNTPOINT/usr/local/bin/kimrity-gate"
  install -Dm644 "$SCRIPT_DIR/gate/README.md" "$MOUNTPOINT/usr/share/doc/kimrity/gate.md"
  # KimScanning engine: kimscan CLI reads rules/en.yaml (English, no AI).
  install -Dm755 "$SCRIPT_DIR/kimscanning/kimscan" "$MOUNTPOINT/usr/local/bin/kimscan"
  install -Dm644 "$SCRIPT_DIR/kimscanning/rules/en.yaml" "$MOUNTPOINT/usr/local/share/kimscanning/rules/en.yaml"
  install -Dm644 "$SCRIPT_DIR/kimscanning/USAGE.md" "$MOUNTPOINT/usr/share/doc/kimrity/kimscanning-usage.md"
  install -Dm644 "$SCRIPT_DIR/kimscanning/README.md" "$MOUNTPOINT/usr/share/doc/kimrity/kimscanning.md"

  # semgrep: not packaged by Arch — venv keeps it away from system python.
  # Proven working on Python 3.14 during the A4 test (8 Nov).
  # FAIL-SOFT (15 Nov, daily-use fix): semgrep is a ~72 MB wheel, and one stalled
  # download used to abort the whole install at step 11/12. It now warns and the
  # install finishes; kimrity-gate reports the missing engine, and the fix is the
  # single rerun printed below. Short timeouts mean a dead mirror fails fast.
  # KIMRITY_PIP_FIND_LINKS=<dir|http://host:port> installs from a local wheelhouse
  # (offline/fast test): KIMRITY_PIP_FIND_LINKS=http://10.0.2.2:8000 ./install.sh ...
  # An http:// wheelhouse also gets --trusted-host <host> (see the helper above).
  if [ -n "$find_links" ]; then
    info "semgrep: pip wheelhouse only -> $find_links${trust_host:+ (trusted-host $trust_host)}"
  fi

  if run arch-chroot "$MOUNTPOINT" python -m venv /opt/semgrep-venv &&
     run arch-chroot "$MOUNTPOINT" /opt/semgrep-venv/bin/pip install "${pip_args[@]}" semgrep; then
    info "semgrep installed (/opt/semgrep-venv/bin/semgrep)"
  else
    warn "semgrep could not be installed — kimrity-gate will report it missing; rerun: arch-chroot $MOUNTPOINT /opt/semgrep-venv/bin/pip install semgrep"
  fi

  # Only link what is really there: a broken symlink looks installed to `command -v`.
  if [ -x "$MOUNTPOINT/opt/semgrep-venv/bin/semgrep" ]; then
    run arch-chroot "$MOUNTPOINT" ln -sf /opt/semgrep-venv/bin/semgrep /usr/local/bin/semgrep
  else
    info "no /usr/local/bin/semgrep symlink (venv binary missing — sees the warn above)"
  fi

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

install_kim_services() {
  # KimAI + KimLogPipe: the two tools that were still dormant after build 11.
  # Both ship in the default profile: the OS is meant to explain itself, and
  # neither tool costs anything while idle.
  step "12/12 KimAI broker + KimLogPipe live pipeline (systemd user units)"

  if [ "$DRY" = 1 ]; then
    printf '[dry] kimai + kimlogpipe -> /usr/local/bin (mode 755)\n'
    printf '[dry] rules.yaml -> /usr/local/share/kimlogpipe/rules.yaml\n'
    printf '[dry] systemd user units -> /usr/lib/systemd/user + enable symlinks\n'
    printf '[dry] audit rules -> /etc/audit/rules.d/kimrity.rules (key etc_watch)\n'
    printf '[dry] auditd: log_group = systemd-journal + systemctl enable auditd\n'
    printf '[dry] hardening: sysctl + sshd + audit identity drop-ins (0644, sshd -t + sysctl --system, best effort)\n'
    printf '[dry] ssh-keygen -A + sshd -t inside the chroot (drop-in removed only on a real config error)\n'
    return 0
  fi

  install -Dm755 "$SCRIPT_DIR/kimai/kimai" "$MOUNTPOINT/usr/local/bin/kimai"
  install -Dm644 "$SCRIPT_DIR/kimai/README.md" "$MOUNTPOINT/usr/local/share/kimai/README.md"
  install -Dm644 "$SCRIPT_DIR/kimai/config.example.toml" \
    "$MOUNTPOINT/usr/local/share/kimai/config.example.toml"

  install -Dm755 "$SCRIPT_DIR/kimlogpipe/kimlogpipe" "$MOUNTPOINT/usr/local/bin/kimlogpipe"
  install -Dm644 "$SCRIPT_DIR/kimlogpipe/rules.yaml" \
    "$MOUNTPOINT/usr/local/share/kimlogpipe/rules.yaml"
  install -Dm644 "$SCRIPT_DIR/kimlogpipe/README.md" "$MOUNTPOINT/usr/local/share/kimlogpipe/README.md"

  # systemd --user cannot be driven from inside arch-chroot, so the units are
  # installed system-wide for user sessions and enabled with a plain symlink.
  install -Dm644 "$SCRIPT_DIR/systemd/user/kimai.service" \
    "$MOUNTPOINT/usr/lib/systemd/user/kimai.service"
  install -Dm644 "$SCRIPT_DIR/systemd/user/kimlogpipe.service" \
    "$MOUNTPOINT/usr/lib/systemd/user/kimlogpipe.service"
  install -d -m 755 "$MOUNTPOINT/etc/systemd/user/default.target.wants"
  ln -sf /usr/lib/systemd/user/kimai.service \
    "$MOUNTPOINT/etc/systemd/user/default.target.wants/kimai.service"
  ln -sf /usr/lib/systemd/user/kimlogpipe.service \
    "$MOUNTPOINT/etc/systemd/user/default.target.wants/kimlogpipe.service"

  # auditd watches /etc so etc_watch produces etc_change events for KimLogPipe.
  # 0644, not 0640: `kimscan posture` counts the watches as your user and the
  # rule list is not a secret. auditd itself only reads them at load time.
  install -Dm644 "$SCRIPT_DIR/systemd/system/kimrity-audit.rules" \
    "$MOUNTPOINT/etc/audit/rules.d/kimrity.rules"

  # auditd lives here, not in step 6: the audit package only arrives in step 9,
  # and `systemctl enable auditd` on a missing unit exits 1 and aborts the run.
  # log_group matches the systemd-journal membership added in step 6, which is
  # what lets KimLogPipe read /var/log/audit/audit.log.
  if [ -f "$MOUNTPOINT/etc/audit/auditd.conf" ]; then
    run sed -i 's/^log_group =.*/log_group = systemd-journal/' "$MOUNTPOINT/etc/audit/auditd.conf"
    run arch-chroot "$MOUNTPOINT" systemctl enable auditd
  else
    warn "audit is not installed — auditd not enabled (kimlogpipe has no audit source)"
  fi

  # Hardening payload (A, 16 Nov): these three files have shipped in the ISO
  # since build 10, but no step ever applied them — the operator believed the
  # machine was hardened when it was not. Best effort on purpose: this is the
  # last step of a finished install, so a missing file or a rejected drop-in
  # must warn and continue, never abort.
  local hn=0 pair hsrc hdst
  for pair in \
    "hardening/sysctl/90-hardening.conf:/etc/sysctl.d/90-hardening.conf" \
    "hardening/sshd/10-hardening.conf:/etc/ssh/sshd_config.d/10-hardening.conf" \
    "hardening/audit/10-identity.rules:/etc/audit/rules.d/10-identity.rules"
  do
    hsrc="$SCRIPT_DIR/${pair%%:*}"; hdst="$MOUNTPOINT${pair#*:}"
    if [ ! -f "$hsrc" ]; then
      warn "hardening source missing: ${pair%%:*} — skipped"
    elif install -Dm644 "$hsrc" "$hdst"; then
      hn=$((hn + 1))
    else
      warn "hardening: could not write ${pair#*:} — skipped"
    fi
  done

  # The audit rule file ships with __USER_HOME__ because a repo cannot know the
  # login name. An audit watch on a missing path is accepted by auditd and then
  # monitors nothing, so this substitution is not cosmetic.
  local arules="$MOUNTPOINT/etc/audit/rules.d/10-identity.rules"
  if [ -f "$arules" ] && grep -q '__USER_HOME__' "$arules"; then
    run sed -i "s|__USER_HOME__|/home/$USERNAME|g" "$arules"
    info "audit identity rules: __USER_HOME__ -> /home/$USERNAME"
  fi

  # sshd: validate the drop-in INSIDE the chroot. On a config failure remove it
  # — a bad sshd config locks the operator out, so sshd keeps its default config
  # and the install still finishes.
  local sshd_dropin="$MOUNTPOINT/etc/ssh/sshd_config.d/10-hardening.conf"
  if [ -f "$sshd_dropin" ]; then
    # sshd -t wants /run/sshd, the same dir the unit creates via RuntimeDirectory
    arch-chroot "$MOUNTPOINT" mkdir -p /run/sshd 2>/dev/null || true
    # openssh ships NO host keys: sshd-gen-keys.service makes them on first boot.
    # Without this, `sshd -t` in the chroot dies with "no hostkeys available"
    # and a VALID drop-in would be deleted as if it were broken.
    if arch-chroot "$MOUNTPOINT" ssh-keygen -A >/dev/null 2>&1; then
      if arch-chroot "$MOUNTPOINT" sshd -t; then
        info "sshd -t: hardening drop-in accepted"
      else
        rm -f "$sshd_dropin"; hn=$((hn - 1))
        warn "sshd -t rejected the hardening drop-in — removed it (sshd stays on its default config)"
      fi
    else
      # Cannot generate keys -> the config cannot be verified. Keep the drop-in:
      # deleting a config we never validated is worse than shipping it.
      warn "ssh-keygen -A failed — sshd -t skipped; hardening drop-in kept (check 'sshd -t' on first boot)"
    fi
  fi

  # sysctl --system proves the file parses and applies the values to the running
  # kernel now; the installed system applies /etc/sysctl.d on every boot anyway.
  if [ -f "$MOUNTPOINT/etc/sysctl.d/90-hardening.conf" ]; then
    if arch-chroot "$MOUNTPOINT" sysctl --system >/dev/null; then
      info "sysctl --system: hardening values applied"
    else
      warn "sysctl --system reported an error — drop-in installed, values apply on boot"
    fi
  fi

  info "KimAI, KimLogPipe, rules and audit watches installed; hardening: ${hn}/3 drop-ins (sysctl + sshd + audit identity)"
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

  1. Passwords: prompted below (skip with --no-password). Manual fallback:
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

  # Passwords (15 Nov): `useradd` leaves '!' in /etc/shadow, so sudo cannot
  # authenticate and hyprlock (auth include login) cannot unlock. tty1 autologin
  # hides that, but the machine ends up with no admin path. passwd talks to the
  # terminal directly — nothing is piped in, nothing is captured.
  if [ "$NO_PASSWORD" = 1 ] || [ ! -t 0 ]; then
    warn "passwords not set — sudo and the hyprlock lock screen will not work until you run: arch-chroot $MOUNTPOINT passwd $USERNAME"
  elif [ "$DRY" = 1 ]; then
    printf '[dry] arch-chroot %s passwd\n' "$MOUNTPOINT"
    printf '[dry] arch-chroot %s passwd %s\n' "$MOUNTPOINT" "$USERNAME"
  else
    step "Passwords (needed for sudo and the lock screen)"
    printf '    %-13s%s\n' "root:" "arch-chroot $MOUNTPOINT passwd"
    printf '    %-13s%s\n' "$USERNAME:" "arch-chroot $MOUNTPOINT passwd $USERNAME"

    # A failed or Ctrl-C'd passwd must not turn a finished install into a
    # failure: catch SIGINT locally, warn, and keep going.
    local interrupted=0
    trap 'interrupted=1' INT
    if arch-chroot "$MOUNTPOINT" passwd; then :; else
      interrupted=1; warn "root password not set"
    fi
    if [ "$interrupted" = 0 ]; then
      if arch-chroot "$MOUNTPOINT" passwd "$USERNAME"; then :; else
        interrupted=1; warn "$USERNAME password not set"
      fi
    fi
    trap - INT
    if [ "$interrupted" = 1 ]; then
      warn "password setup incomplete — run: arch-chroot $MOUNTPOINT passwd $USERNAME"
    fi
  fi

  # Key-only SSH is the intended policy (hardening/sshd/10-hardening.conf), but
  # nothing on a fresh machine has a key yet, so say it loud at the end.
  warn "SSH is key-only (PasswordAuthentication no). No key is installed yet:"
  info "add ~/.ssh/authorized_keys or you cannot log in over SSH."
}

# ---------------------------------------------------------------------- main
main() {
  if [ "$DRY" = 0 ]; then
    if mkdir -p "$(dirname "$LOG")" 2>/dev/null && { : >> "$LOG"; } 2>/dev/null; then
      # trap - ERR first: the tee child inherits the failure trap otherwise and
      # would print a stale "step setup" line when it exits (non-root tests).
      # The writability probe above matters: a tee that cannot open the log
      # exits at once and swallows every later message.
      exec > >(trap - ERR; exec tee -a "$LOG") 2>&1
    else
      warn "no log file: cannot write $LOG (run as root) — continuing on the terminal"
    fi
  fi

  # Resolved settings, printed before anything is touched. A dry run is only
  # useful if it shows the values it would use (old runs silently assumed
  # en_US/us even after the operator asked for something else).
  info "disk=$DISK  dry_run=$DRY"
  info "hostname=$HOSTNAME  user=$USERNAME (uid $USER_UID)  timezone=$TIMEZONE"
  info "locale=$LOCALE  keymap=$KEYMAP  mountpoint=$MOUNTPOINT  opts=$MOUNT_OPTS"
  info "target: root subvol=$ROOT_SUBVOL  home=$HOME_SUBVOL  snapshots=$SNAP_SUBVOL  esp=$ESP_LABEL"

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
  install_kim_services
  install_lab
  install_flatpak_tools
  finish
}

main "$@"
