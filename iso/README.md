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
    └── root/              carried into the live ISO (written by tools/sync-iso.sh):
        ├── install.sh     the installer (12 steps)
        ├── dotfiles/      Hyprland (Lua), waybar, kitty, quickshell, local-bin
        ├── hardening/     audit rules, sysctl, sshd (installed by step 12)
        ├── gate/          Security Gate (gate.py + README)
        ├── kimai/         approval broker (user unit)
        ├── kimlogpipe/    journald + auditd pipeline (user unit)
        ├── kimscanning/   posture / baseline / report engine + rules
        ├── systemd/       user units + audit rules
        ├── tools/         arsenal lists, sync-iso, verify-iso, build-iso
        └── lab/           lab artifact rule + reports (opt-in)
```

## Build

Never build from a stale profile. The supported way is one command:

```sh
./tools/build-iso.sh            # sync -> mkarchiso -> verify-iso.sh
./tools/build-iso.sh --no-verify
```

What it wraps (same as the manual form, both need root for mkarchiso):

```sh
./tools/sync-iso.sh             # repo -> iso/airootfs; --check reports drift
sudo mkarchiso -v -w /var/tmp/kimrity-work -o iso-out ./iso
./tools/verify-iso.sh iso-out/kimrity-YYYY.MM.DD-x86_64.iso
```

`sync-iso.sh` exists because the ISO profile holds **copies**: on 14 Nov a stale
`kimscanning/rules/en.yaml` (33 entries instead of 41) shipped inside a fresh
ISO, and only `verify-iso.sh` caught it.

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
4. **`-cdrom` when testing in QEMU** — attaching the ISO as `usb-storage`
   gives `Write Protected` and the firmware falls through to PXE (14 Nov).

## Inside the ISO (live)

`install.sh` runs directly from the live environment:

```sh
KIMRITY_PIP_FIND_LINKS=http://10.0.2.2:8000 \
  bash /root/install.sh --disk /dev/vda --yes --efi
```

Lab tooling is **opt-in**: `--lab` adds the BlackArch repo (key + mirrorlist)
and installs `tools/arsenal.list`; `--flatpak` adds the Flatpak slots. The
default install is the lean daily system — see the repo `README.md`.
