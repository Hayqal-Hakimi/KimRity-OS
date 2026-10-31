# KimRity ISO profile (archiso)

```
iso/
├── profiledef.sh          name/label/version, bootmodes, file_permissions
├── pacman.conf            REQUIRED — mkarchiso uses it to build airootfs
├── packages.x86_64        live environment packages
├── efiboot/
│   └── loader/
│       ├── loader.conf            timeout, default entry
│       └── entries/01-archiso-linux.conf   title KimRity Live
└── airootfs/
    ├── etc/os-release     NAME="KimRity", ID=kimrity
    ├── etc/motd
    └── root/              carried into the live ISO:
        ├── install.sh     installer (10 steps, includes the arsenal)
        ├── dotfiles/      Hyprland, waybar, kitty
        ├── hardening/     audit rules, sysctl, sshd
        ├── lab/           artifact rule + reports
        ├── gate/          Security Gate (gate.py + README)
        └── tools/         arsenal.list, arsenal-ai.list, setup-blackarch.sh
```

## Build

```sh
mkarchiso -v -w /var/tmp/kimrity-work -o ~/iso ~/kimrity-profile
```

## Things that are REQUIRED (without them, mkarchiso fails)

1. **`pacman.conf`** at the profile root — error: `File '…/pacman.conf' does not exist`.
2. **`efiboot/loader/entries/`** when `bootmodes=('uefi.systemd-boot')` —
   error: `The '…/efiboot/loader/entries' directory is missing`.
   Placeholders in the entry: `%ARCH%`, `%INSTALL_DIR%`, `%ARCHISO_UUID%`, `%KERNEL_PARAMS%`.
3. **`file_permissions` entries must resolve in the built airootfs** —
   paths created by packages during pacstrap (e.g. `/etc/shadow`,
   `/etc/gshadow`) may be listed even though they don't exist in the
   profile tree. Listing a path that never appears in the built tree
   fails: `Failed to set permissions on '…': Outside of valid path`
   and the build stops.
   (Verified 30 Oct, archiso 91: the build passed although
   `/etc/shadow` and `/etc/gshadow` are absent from the profile —
   they are created by the `filesystem` package during pacstrap.)

## Inside the ISO (live)

`install.sh` can be run directly from the live environment. Step 10/10
adds the BlackArch repo (key + mirrorlist) and installs `tools/arsenal.list`
(24 core packages) + `gate.py` → `/usr/local/bin/kimrity-gate`.
`--ai` adds `tools/arsenal-ai.list` (heavy: garak 6.4 GB, promptfoo 1.7 GB).
