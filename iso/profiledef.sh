#!/usr/bin/env bash
# KimRity ISO profile — Arch + Hyprland security workstation
# Berdasarkan struktur releng archiso 91.
# shellcheck disable=SC2034

iso_name="kimrity"
iso_label="KIMRITY_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="KimRity"
iso_application="KimRity Live / Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/install.sh"]="0:0:755"
  ["/root/gate/gate.py"]="0:0:755"
  ["/root/tools/setup-blackarch.sh"]="0:0:755"
)
