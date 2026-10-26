#!/usr/bin/env bash
# =============================================================================
# install.sh — pemasang Arch + Hyprland minimal untuk projek os-security-ai
#
# Dijalankan dari Arch ISO (atau sistem Arch yang ada arch-install-scripts)
# sebagai root. Ia MEMUSNAHKAN disk yang diberi — tiada nilai lalai.
#
#   ./install.sh --disk /dev/vda --hostname arch-uji --user hayqal
#   ./install.sh --disk /dev/vda --dry-run        # cetak sahaja, tiada perubahan
#
# Selepas siap: `passwd` (root) dan `passwd <user>` — password TIDAK pernah
# ditetapkan oleh skrip ini.
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- tetapan lalai
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
ARSENAL=1
AI_PKGS=0

BASE_PKGS=(base linux linux-firmware btrfs-progs networkmanager sudo neovim limine efibootmgr openssh)
DESKTOP_PKGS=(hyprland kitty waybar wofi mako xdg-desktop-portal-hyprland xdg-desktop-portal
              polkit hyprpolkitagent pipewire pipewire-pulse wireplumber mesa
              ttf-jetbrains-mono-nerd)
TOOL_PKGS=(git base-devel btop wl-clipboard grim slurp tcpdump nmap audit yara firefox gptfdisk iputils inetutils)

# --------------------------------------------------------------------- utiliti
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
Guna: $(basename "$0") --disk /dev/XXX [pilihan]

  --disk PATH      (WAJIB) disk sasaran, contoh /dev/vda  — akan DIPADAM
  --hostname NAME  lalai: $HOSTNAME
  --user NAME      lalai: $USERNAME (UID 1000, kumpulan wheel)
  --timezone TZ    lalai: $TIMEZONE
  --dotfiles DIR   lalai: $DOTFILES_DIR
  --yes            jangan minta pengesahan bertaip
  --force          benarkan disk yang ada partisi NTFS (Windows)
  --efi            VM: tulis entri NVRAM Limine melalui efibootmgr
  --no-arsenal     jangan pasang tool BlackArch + Security Gate
  --ai             pasang juga tool AI security berat (garak, promptfoo…)
  --dry-run        cetak arahan sahaja, tiada perubahan
  -h, --help
EOF
}

# ------------------------------------------------------------------ hujah CLI
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
    --no-arsenal) ARSENAL=0; shift ;;
    --ai)        AI_PKGS=1; shift ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "hujah tidak dikenali: $1 (guna --help)" ;;
  esac
done

# partisi: /dev/vda1 tetapi /dev/nvme0n1p1
part() {
  case "$DISK" in
    *nvme*|*mmcblk*) printf '%sp%s' "$DISK" "$1" ;;
    *)               printf '%s%s' "$DISK" "$1" ;;
  esac
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "alat tiada: $1"; }

# ------------------------------------------------------------------- preflight
preflight() {
  step "Preflight"

  [ "$(id -u)" -eq 0 ] || die "mesti dijalankan sebagai root"
  [ -n "$DISK" ] || die "--disk WAJIB (tiada nilai lalai — ini memadam disk)"

  [ -b "$DISK" ] || die "$DISK bukan block device"
  [ -d "/sys/block/$(basename "$DISK")" ] || die "$DISK bukan disk penuh (jangan beri partisi)"

  info "disk sasaran : $DISK ($(lsblk -dno SIZE "$DISK" | tr -d ' '))"
  info "hostname     : $HOSTNAME"
  info "user         : $USERNAME (UID $USER_UID)"
  info "zon masa     : $TIMEZONE"
  info "dotfiles     : $DOTFILES_DIR"

  # Elak memadam disk yang sedang memegang ISO
  local iso_src iso_parent
  iso_src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
  if [ -n "$iso_src" ]; then
    iso_parent="$(lsblk -no PKNAME "$iso_src" 2>/dev/null | head -1 || true)"
    [ "$iso_parent" = "$(basename "$DISK")" ] && \
      die "disk ini memegang ISO yang sedang berjalan — pilih disk lain"
  fi

  # Elak memadam Windows (peraturan projek: sda tidak boleh disentuh)
  if lsblk -no FSTYPE "$DISK" 2>/dev/null | grep -qx 'ntfs'; then
    [ "$FORCE" = 1 ] || die "disk ini mengandungi NTFS (Windows). Guna --force hanya jika betul-betul pasti"
    warn "disk ada NTFS — diteruskan kerana --force"
  fi

  # Jangan sentuh disk yang ada partisi dilekap
  if lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -qv '^$'; then
    die "ada partisi pada $DISK yang masih dilekap — nyahlekap dahulu"
  fi

  if [ ! -d /sys/firmware/efi ]; then
    die "sistem ini bukan UEFI (tiada /sys/firmware/efi) — skrip ini hanya untuk UEFI"
  fi

  local size_gib
  size_gib=$(lsblk -bdno SIZE "$DISK" | awk '{printf "%d", $1/1024/1024/1024}')
  [ "$size_gib" -ge 20 ] || die "disk terlalu kecil (${size_gib} GiB) — perlu ≥ 20 GiB"

  local c
  for c in sgdisk mkfs.fat mkfs.btrfs pacstrap arch-chroot genfstab blkid; do
    need_cmd "$c"
  done
  [ -d "$DOTFILES_DIR" ] || warn "dotfiles tiada: $DOTFILES_DIR — langkah dotfiles akan dilangkau"

  info "semua semakan lulus"
}

confirm() {
  [ "$DRY" = 1 ] && return 0
  [ "$ASSUME_YES" = 1 ] && return 0

  cat <<EOF

$(printf '%s' "$c_red")AMARAN: semua data pada $DISK akan dipadam.$(printf '%s' "$c_off")
Tulis YES untuk teruskan: 
EOF
  local ans; read -r ans
  [ "$ans" = "YES" ] || die "dibatalkan oleh pengguna"
}

# -------------------------------------------------------------------- langkah
partition_disk() {
  step "1/10 Partisi GPT: ${ESP_LABEL} 1 GiB + ${ROOT_LABEL} (baki)"
  run wipefs -a "$DISK"
  run sgdisk --zap-all "$DISK"
  run sgdisk -n "1:0:+1G" -t "1:ef00" -c "1:$ESP_LABEL" "$DISK"
  run sgdisk -n "2:0:0"   -t "2:8300" -c "2:$ROOT_LABEL" "$DISK"
  run udevadm settle

  # tunggu node partisi muncul (kernel/udev, bukan partprobe)
  if [ "$DRY" = 0 ]; then
    local i
    for i in $(seq 1 20); do
      [ -b "$(part 1)" ] && [ -b "$(part 2)" ] && break
      sleep 0.5
    done
    [ -b "$(part 1)" ] && [ -b "$(part 2)" ] || die "partisi tidak muncul selepas partisi"
  fi
}

format_and_mount() {
  local root="${DISK}"; root="$(part 2)"; local esp; esp="$(part 1)"

  step "2/10 Format: vfat (ESP) + btrfs ($ROOT_LABEL)"
  run mkfs.fat -F 32 -n "$ESP_LABEL" "$esp"
  run mkfs.btrfs -f -L "$ROOT_LABEL" "$root"

  step "3/10 Subvolume + lekap ($MOUNT_OPTS)"
  run mount "$root" "$MOUNTPOINT"
  run btrfs subvolume create "$MOUNTPOINT/$ROOT_SUBVOL"
  run btrfs subvolume create "$MOUNTPOINT/$HOME_SUBVOL"
  run umount "$MOUNTPOINT"
  run mount -o "$MOUNT_OPTS,subvol=$ROOT_SUBVOL" "$root" "$MOUNTPOINT"
  run mkdir -p "$MOUNTPOINT/home" "$MOUNTPOINT/boot"
  run mount -o "$MOUNT_OPTS,subvol=$HOME_SUBVOL" "$root" "$MOUNTPOINT/home"
  run mount "$esp" "$MOUNTPOINT/boot"
}

pacstrap_base() {
  step "4/10 pacstrap pakej asas (${#BASE_PKGS[@]} pakej)"
  run pacstrap -K "$MOUNTPOINT" "${BASE_PKGS[@]}"

  step "5/10 genfstab"
  if [ "$DRY" = 1 ]; then
    printf '[dry] genfstab -U %s >> %s/etc/fstab\n' "$MOUNTPOINT" "$MOUNTPOINT"
  else
    genfstab -U "$MOUNTPOINT" >> "$MOUNTPOINT/etc/fstab"
    printf '+ genfstab -U %s >> %s/etc/fstab\n' "$MOUNTPOINT" "$MOUNTPOINT"
  fi
}

chroot_configure() {
  local cfile="$MOUNTPOINT/root/chroot-setup.sh"

  step "6/10 Konfigurasi dalam chroot (zon, locale, hostname, initramfs, user, sudoers)"

  if [ "$DRY" = 1 ]; then
    printf '[dry] tulis %s dan jalankan: arch-chroot %s bash /root/chroot-setup.sh\n' "$cfile" "$MOUNTPOINT"
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

# Log kekal (penemuan artifak #1: journald tidak kekal secara lalai)
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

  step "7/10 Limine (fallback path + limine.conf)"

  if [ "$DRY" = 1 ]; then
    printf '[dry] cp BOOTX64.EFI -> %s/boot/EFI/BOOT/ ; tulis limine.conf (UUID dari blkid)\n' "$MOUNTPOINT"
    return 0
  fi

  uuid="$(blkid -s UUID -o value "$root")"
  [ -n "$uuid" ] || die "tidak dapat UUID untuk $root"

  mkdir -p "$MOUNTPOINT/boot/EFI/BOOT"
  cp "$MOUNTPOINT/usr/share/limine/BOOTX64.EFI" "$MOUNTPOINT/boot/EFI/BOOT/"

  cat > "$MOUNTPOINT/boot/EFI/BOOT/limine.conf" <<CONF
timeout: 5

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=$uuid rw rootflags=subvol=$ROOT_SUBVOL
    module_path: boot():/initramfs-linux.img
CONF

  info "UUID akar: $uuid"

  if [ "$EFI" = 1 ]; then
    run efibootmgr --create --disk "$DISK" --part 1 --label "Limine" \
        --loader '\EFI\BOOT\BOOTX64.EFI' --unicode
  else
    info "entri NVRAM dilangkau (guna --efi untuk VM); fallback path sudah cukup untuk boot"
  fi
}

install_dotfiles() {
  step "8/10 Dotfiles -> /home/$USERNAME"
  if [ ! -d "$DOTFILES_DIR" ]; then
    warn "dotfiles tiada — dilangkau"; return 0
  fi
  if [ "$DRY" = 1 ]; then
    printf '[dry] cp %s/{hypr,kitty,waybar} -> %s/home/%s/.config/ ; bash_profile -> ~/.bash_profile\n' \
      "$DOTFILES_DIR" "$MOUNTPOINT" "$USERNAME"
    return 0
  fi

  local home="$MOUNTPOINT/home/$USERNAME"
  install -d -m 755 "$home/.config"
  local d
  for d in hypr kitty waybar; do
    [ -d "$DOTFILES_DIR/$d" ] || continue
    install -d "$home/.config/$d"
    cp -a "$DOTFILES_DIR/$d/." "$home/.config/$d/"
  done
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
  info "dotfiles disalin"
}

install_packages() {
  step "9/10 Pakej desktop (${#DESKTOP_PKGS[@]}) + tool asas (${#TOOL_PKGS[@]})"
  run arch-chroot "$MOUNTPOINT" pacman -S --needed --noconfirm "${DESKTOP_PKGS[@]}" "${TOOL_PKGS[@]}"
}

install_arsenal() {
  step "10/10 Arsenal BlackArch + Security Gate"
  if [ "$ARSENAL" = 0 ]; then
    info "arsenal dilangkau (--no-arsenal)"; return 0
  fi

  local list="$SCRIPT_DIR/tools/arsenal.list"
  local ai_list="$SCRIPT_DIR/tools/arsenal-ai.list"
  [ -f "$list" ] || { warn "tools/arsenal.list tiada — dilangkau"; return 0; }

  local pkgs=() line
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    pkgs+=("$line")
  done < "$list"

  if [ "$DRY" = 1 ]; then
    printf '[dry] setup-blackarch dalam chroot -> pacman -S %s pakej teras\n' "${#pkgs[@]}"
    [ "$AI_PKGS" = 1 ] && printf '[dry] + group blackarch-ai (%s pakej)\n' \
      "$(grep -vcE '^\s*(#|$)' "$ai_list" 2>/dev/null || echo '?')"
    printf '[dry] gate.py -> /usr/local/bin/kimrity-gate\n'
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

  install -Dm755 "$SCRIPT_DIR/gate/gate.py" "$MOUNTPOINT/usr/local/bin/kimrity-gate"
  install -Dm644 "$SCRIPT_DIR/gate/README.md" "$MOUNTPOINT/usr/share/doc/kimrity/gate.md"
  rm -f "$MOUNTPOINT/root/setup-blackarch.sh"
  info "arsenal (${#pkgs[@]} pakej) + gate dipasang"
}

finish() {
  step "Selesai"
  cat <<EOF

Sistem dipasang pada $DISK. Yang TINGGAL (manual, sengaja):

  1. Tetapkan password (skrip ini tidak menyentuhnya):
       arch-chroot $MOUNTPOINT passwd
       arch-chroot $MOUNTPOINT passwd $USERNAME

  2. Keluar ISO dan boot dari disk:
       umount -R $MOUNTPOINT && reboot

  3. Log masuk sebagai $USERNAME — Hyprland akan start sendiri.
EOF
}

# ----------------------------------------------------------------------- main
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
  install_arsenal
  finish
}

main "$@"
