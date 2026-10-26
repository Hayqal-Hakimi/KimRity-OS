# Profil ISO KimRity (archiso)

```
iso/
├── profiledef.sh          nama/label/versi, bootmodes, file_permissions
├── pacman.conf            WAJIB — mkarchiso guna ini untuk bina airootfs
├── packages.x86_64        pakej live environment
├── efiboot/
│   └── loader/
│       ├── loader.conf            timeout, default entry
│       └── entries/01-archiso-linux.conf   title KimRity Live
└── airootfs/
    ├── etc/os-release     NAME="KimRity", ID=kimrity
    ├── etc/motd
    └── root/              dibawa masuk ke live ISO:
        ├── install.sh     pemasang (10 langkah, termasuk arsenal)
        ├── dotfiles/      Hyprland, waybar, kitty
        ├── hardening/     audit rules, sysctl, sshd
        ├── lab/           rule + laporan artifak
        ├── gate/          Security Gate (gate.py + README)
        └── tools/         arsenal.list, arsenal-ai.list, setup-blackarch.sh
```

## Bina

```sh
mkarchiso -v -w /var/tmp/kimrity-work -o ~/iso ~/kimrity-profile
```

## Perkara yang WAJIB (kalau tiada, mkarchiso gagal)

1. **`pacman.conf`** di akar profil — ralat: `File '…/pacman.conf' does not exist`.
2. **`efiboot/loader/entries/`** bila `bootmodes=('uefi.systemd-boot')` —
   ralat: `The '…/efiboot/loader/entries' directory is missing`.
   Placeholder dalam entry: `%ARCH%`, `%INSTALL_DIR%`, `%ARCHISO_UUID%`, `%KERNEL_PARAMS%`.
3. **`file_permissions` hanya untuk fail yang WUJUD** dalam airootfs —
   menyenaraikan fail yang tiada memberi ralat
   `Failed to set permissions on '…': Outside of valid path` dan binaan berhenti.

## Dalam ISO (live)

`install.sh` boleh dijalankan terus dari live environment. Langkah 10/10
menambah repo BlackArch (kunci + mirrorlist) dan memasang `tools/arsenal.list`
(24 pakej teras) + `gate.py` → `/usr/local/bin/kimrity-gate`.
`--ai` menambah `tools/arsenal-ai.list` (berat: garak 6.4 GB, promptfoo 1.7 GB).
