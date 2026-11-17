# KimRity OS — operator manual

Last verified: 2026-11-17 against `kimrity-2026.11.17-x86_64.iso` (Build 14)

One operator's Arch + Hyprland workstation: a daily desktop, the always-installed host tools
(`kimrity-gate`, `kimscan`), and a local pipeline (`kimai` + `kimlogpipe`) recording what the
machine does. Analysis tooling is opt-in; no AI model sits in any verdict; no encryption; no
swap partition (zram only). Built for an i5-4590 / 7.2 GiB host; the test VM gets 1792 MB.

## 1. What it is, and the budget it is built to

| Target | Value | How it is held |
|---|---|---|
| Installed footprint | ≤ 5 GB | `yes \| pacman -Scc` is the last install step; check `df -h /` |
| ISO size | ≤ 1.4 GB | `tools/verify-iso.sh` fails above 1,400,000,000 bytes |
| Idle RAM, boot time | ≤ 900 MB, ≤ 12 s | measured in the installed system: `free -m` 686 MiB, `systemd-analyze` 7.804 s (Build 14) |

## 2. Build the ISO

```sh
./tools/build-iso.sh          # sync + drift gate + mkarchiso + verify-iso (root)
./tools/sync-iso.sh --check   # drift only: exit 1 when iso/airootfs is stale
```

- `tools/build-iso.sh` runs `mkarchiso -v -w /var/tmp/kimrity-work -o iso-out iso` as root
  (`KIMRITY_WORK` / `KIMRITY_OUT` override both paths) and needs ≥ 8 GiB free in `/var/tmp`.
  Root is obtained with `sudo -n` when that works, otherwise `pkexec`: the passwordless `sudo`
  grant on this host is temporary, and a plain `sudo` build dies with
  `sudo: a terminal is required to read the password`.
  It always runs `sync-iso.sh` first: the ISO carries **copies** of the repo, and a stale copy
  has shipped before (an old `kimscanning/rules/en.yaml`, caught only by `verify-iso.sh`).
- The profile is `iso/` (`profiledef.sh`: `iso_name=kimrity`, `uefi.systemd-boot`, squashfs xz);
  the last build left `iso-out/kimrity-2026.11.17-x86_64.iso` (1.24 GiB, sha256
  `864a3a9b…`, `verify-iso.sh` 19/19, and a full install/boot/reboot test on a blank 24 GiB disk).
  `iso-out/` holds exactly one ISO: delete the old one after the new one verifies.
- `iso/README.md` documents the profile (required files, build command, `-cdrom` gotcha).
  `iso/pacman.conf` is required by
  mkarchiso; `iso/packages.x86_64` is the live environment only. Test on a bare VT, else the host
  compositor eats the guest's `SUPER` keys: `tools/vm-on-vt.sh <iso> <disk.img> [vt] [mem_mb]`
  (image must exist; default VT 8, 1792 MB, OVMF, SSH on 127.0.0.1:2223).

## 3. Install from the live ISO

Boot the ISO, log in as root, then `bash /root/install.sh --disk /dev/vda --efi`.

> **Every partition on `--disk` is erased** (`wipefs -a` + `sgdisk --zap-all`); there is no
> default disk. Preflight aborts on: not root (unless `--dry-run`), `--disk` missing, not a
> block device, a partition instead of a whole disk, the disk holding the running ISO, any
> mounted partition, NTFS without `--force`, no `/sys/firmware/efi`, or under 20 GiB. The
> result is **not encrypted** — `hyprlock` is a lock screen, not disk protection.

| Flag | Default | Effect |
|---|---|---|
| `--disk PATH` | **required** | whole disk, e.g. `/dev/vda` — erased |
| `--hostname NAME` / `--user NAME` | `kimrity` / `hayqal` | hostname; user UID 1000 + group `wheel` |
| `--timezone TZ` | `Asia/Kuala_Lumpur` | `/etc/localtime` + `hwclock --systohc` |
| `--locale LOCALE` | `en_US.UTF-8` | `/etc/locale.gen` + `/etc/locale.conf` |
| `--keymap KM` | `us` | `/etc/vconsole.conf` (console keyboard — a wrong keymap can make recovery typing painful) |
| `--dotfiles DIR` | `<script dir>/dotfiles` | alternate dotfiles source |
| `--yes` / `--dry-run` | off | skip typed `YES` / print commands only (may run as a user) |
| `--force` / `--efi` | off | allow NTFS disk / Limine NVRAM entry (needed in VMs) |
| `--lab` / `--ai` / `--flatpak` | off | arsenal from `tools/arsenal.list` / also `arsenal-ai.list` (implies `--lab`) / flatpak + Flathub, no apps |
| `--no-password` | off | skip the end-of-install `passwd` prompts (sudo and hyprlock stay unusable) |
| `--no-arsenal` / `-h`, `--help` | — | accepted for old scripts (warns lab is opt-in) / usage |

Layout: GPT, ESP 1 GiB (vfat, label `ESP`), btrfs (label `arch`); subvolumes `@`, `@home`, and
`@snapshots` as a **sibling of `@`** (mounted at `/.snapshots` in step 10, not at format time);
`@` and `@home` mount `compress=zstd:3,noatime` (btrfs + snapper rewrite atime constantly;
nothing here reads it, and `genfstab` records the live options so fstab inherits them). Limine goes to `/boot/EFI/BOOT/BOOTX64.EFI` +
`limine.conf` (2 s timeout, `/Arch Linux`), plus a Windows entry if that ESP already holds one.

Twelve numbered steps: `1/12` GPT, `2/12` format, `3/12` subvolumes+mount, `4/12` pacstrap base,
`5/12` genfstab, `6/12` chroot config, `7/12` Limine, `8/12` dotfiles, `9/12` desktop+apps+tools,
`10/12` snapper stack, `11/12` gate+kimscan, `12/12` KimAI+KimLogPipe; then unnumbered `--lab`,
`--flatpak`, cache cleanup, `Done`. A failure prints `step N/12 (<name>) failed at: <command>`
plus `/var/log/install-arch.log` (live RAM overlay, gone after reboot). No `--step`, no
encryption flag, no swap flag. **Passwords are set at the very end** on a TTY:
`arch-chroot /mnt passwd` then `arch-chroot /mnt passwd hayqal`, then `umount -R /mnt && reboot`.
`--no-password` skips both prompts for scripted runs (it prints a warning: sudo and hyprlock stay
unusable until you set one). Before any partition is touched, the resolved settings are printed —
disk, hostname, user, timezone, locale, keymap, mount options, subvolume names — so a dry run
shows exactly what it *would* do.

## 4. What you get after install

- **Desktop:** Hyprland (Lua config, ≥ 0.56 — verified against 0.57.1), waybar, quickshell
  (`qs -c kimrity`), mako, wofi, kitty, hyprlock, hypridle, hyprpolkitagent, cliphist, swaybg,
  playerctl, portals, pipewire + wireplumber, mesa. Autostart: waybar, quickshell, mako,
  wallpaper, hypridle, hyprpolkitagent, 2× `wl-paste --watch cliphist`.
- **Daily apps:** firefox, zathura + zathura-pdf-mupdf, qalculate-gtk, mpv, telegram-desktop,
  yazi, neovim, btop; defaults set per user (PDF → zathura, video → mpv, web → firefox).
- **Host security:** `kimrity-gate` (gate.py: repo / web / server verdict; active scans need
  `--authorized`), `kimscan` (repo, file, installer, web, server, posture, report, list, show,
  status, rules, doctor), gitleaks, trivy, nikto, ssh-audit, nmap, tcpdump, auditd, semgrep in
  `/opt/semgrep-venv` (fail-soft), nuclei v3.11.1 (best effort).
- **Pipeline:** user units `kimai.service` (broker + event sink, socket in
  `$XDG_RUNTIME_DIR/kimai.sock`) and `kimlogpipe.service` (`follow`: journald + audit log →
  findings → KimAI), enabled via `/etc/systemd/user/default.target.wants/`; the user joins
  `systemd-journal` and a linger marker keeps both alive with no terminal open.
- **System:** NetworkManager, sshd, auditd enabled; `getty@tty1` autologin; both snapper timers;
  persistent journal; `/etc/audit/rules.d/kimrity.rules` watches identity files under key
  `etc_watch`; zram swap `min(ram / 2, 4096)` MB, zstd; step 12 installs the three
  `hardening/` drop-ins (sysctl, sshd key-only, audit identity). `dotfiles/nftables.conf` ships
  but is never applied: its allowed SSH source is the single `define SSH_SRC = 10.0.2.2` (QEMU
  NAT), which would lock out real hardware until you change that one line (section 8). Also set:
  `timesyncd` enabled, `fstrim.timer` enabled, fstab sanity checks (`btrfs` root line, `subvol=/@`).

## 5. First-boot checklist

```sh
passwd -S                                          # "P" = a password exists; L/NP = sudo and hyprlock cannot authenticate
pgrep -x Hyprland && systemctl --user is-active waybar
swapon --show                                      # /dev/zram0
df -h /                                            # footprint vs the 5 GB target
kimscan doctor
sudo -E kimscan posture | grep Coverage            # shadow + sudoers need root
~/verify-installed.sh                              # 66 checks, exit 1 on a FAIL
                                                   # (copy from /root/tools/ on the live ISO)
```

Two traps worth knowing on a fresh install:

- **No password = no sudo and no lock screen.** `install.sh` asks for both passwords at the
  end on a TTY (`--no-password` skips). Until one is set, `sudo` cannot authenticate and
  `~/.local/bin/lock` refuses to lock (hyprlock uses PAM, which rejects a locked account) and
  shows a notification instead. Set one with `passwd`, then `SUPER + L` works normally.
- **SSH is key-only** (`PasswordAuthentication no`) and no key is installed by the script.
  Add `~/.ssh/authorized_keys` from the console before you rely on SSH.

## 6. Keybindings (from `dotfiles/hypr/hyprland.lua`)

| Keys | Action |
|---|---|
| `SUPER + RETURN` / `SUPER + W` | kitty / close window (`SUPER + Q` deliberately unbound) |
| `SUPER + SHIFT + E` / `SUPER + SHIFT + V` | exit Hyprland / toggle floating |
| `SUPER + D` / `SUPER + V` | quickshell menu / clipboard menu (`cliphist-menu`) |
| `SUPER + E` / `B` / `C` / `N` | yazi / firefox / qalculate-gtk / nvim (all `SUPER`-prefixed) |
| `SUPER + SHIFT + K` | `kimscan posture` in `kitty --hold` |
| `SUPER + F` / `P` / `J` | fullscreen / pseudo-tile / toggle split |
| `SUPER + TAB` / `SHIFT + TAB` | next window / previous window |
| `SUPER + ←→↑↓` / `+ CTRL` | focus / resize by 40 px |
| `SUPER + 1..5` / `+ SHIFT` | switch workspace / move window there |
| `SUPER + wheel` / `SUPER + drag` / `right-drag` | next-prev workspace / move / resize |
| `SUPER + GRAVE` / `+ SHIFT` | scratchpad `magic` / move window to it |
| `SUPER + F1..F3` | workspace presets (`workspace-launch`, `~/.config/kimrity/workspaces.conf`) |
| `SUPER + L` / `SUPER + SHIFT + Q` | `~/.local/bin/lock` (hyprlock, gated on a password) / power menu |
| `PRINT` / `SUPER + SHIFT + S` / `XF86Audio*` | screenshot (full / region) to `$KIMRITY_SHOT_DIR` (default `~/Pictures`); volume, mute, play, next, prev |

## 7. Where things live

| Path | Contents |
|---|---|
| `~/.config/hypr/{hyprland.lua,hypridle.conf,hyprlock.conf}`, `~/.config/{kitty,waybar,wofi,quickshell/kimrity}`, `~/.config/kimrity/workspaces.conf` | Hyprland; idle (lock 5 min, DPMS off 15 min); lock screen; apps, bar, launcher, menu, F1–F3 presets |
| `~/.local/bin/` | `lock`, `menu-toggle`, `cliphist-menu`, `powermenu`, `screenshot`, `wallpaper`, `workspace-launch`, `kimrity-{apps,flatpak,gate,icons,menu,tools,ws}` — **not on `PATH`** (the shipped `bash_profile` adds nothing), so call them by full path, as Hyprland does |
| `~/.bash_profile` | `exec Hyprland` on tty1 only (no `DISPLAY`, `WAYLAND_DISPLAY`, `SSH_CONNECTION`, not already running) |
| `/usr/local/bin/`, `/usr/local/share/{kimscanning,kimai,kimlogpipe}/`, `/usr/share/doc/kimrity/` | `kimrity-gate` (= `gate/gate.py`), `kimscan`, `kimai`, `kimlogpipe`, `semgrep` symlink (if the venv build worked), `nuclei`; scanner rules, `config.example.toml`, pipeline `rules.yaml`, READMEs, usage docs |
| `/usr/lib/systemd/user/*.service`, `/etc/systemd/user/default.target.wants/`, `/etc/systemd/system/getty@tty1.service.d/autologin.conf`, `/etc/systemd/zram-generator.conf` | user units + links, autologin, zram |
| `/etc/audit/rules.d/kimrity.rules`, `/boot/EFI/BOOT/{BOOTX64.EFI,limine.conf}` | audit watches, Limine |
| `~/.local/share/{kimscanning,kimlogpipe,kimai}/` | sessions + posture baseline, `events.jsonl`/`findings.jsonl`, `events.jsonl`/`approvals.jsonl` |

```sh
journalctl -b                                        # this boot
journalctl -u NetworkManager -u sshd -u auditd -b
journalctl --user -u kimai -u kimlogpipe -b          # -f to follow live
```

## 8. Troubleshooting

- **Black screen, no Hyprland** — switch VT (`Ctrl+Alt+F2`), log in, `pgrep -x Hyprland`,
  `journalctl -b -u getty@tty1`; start `Hyprland` by hand and read the error, then re-check each
  `~/.bash_profile` condition (only `hyprland.lua` ships: Hyprland < 0.56 has no config).
- **No audio / no network** — audio: `systemctl --user status pipewire pipewire-pulse
  wireplumber`, `wpctl status`, `systemctl --user restart wireplumber pipewire-pulse`. Network:
  `ip -4 -br addr`, `systemctl status NetworkManager`, `nmcli device status`, `nmcli connection
  up <name>`. No Wi-Fi backend (`wpa_supplicant`/`iwd`) is in the package arrays — `TODO: verify`
  before promising Wi-Fi; wired is what the build exercises.
- **zram not active** — `zramctl` and `swapon --show` should show `/dev/zram0`; else
  `systemctl status systemd-zram-setup@zram0.service`, re-check `/etc/systemd/zram-generator.conf`,
  then `systemctl daemon-reload && systemctl start systemd-zram-setup@zram0.service`.
- **`kimscan posture` says checks "not evaluated"** — normal as a user: `shadow` and `sudoers`
  need root, so 10 of 12. Root adds those two, but `pipeline` needs `$XDG_RUNTIME_DIR`, so use
  `sudo -E kimscan posture` (plain `sudo` can land on 11 of 12); `--strict` turns any skipped
  check into CONDITIONAL (exit 2).
- **Service not running** — `systemctl --user status kimai kimlogpipe`, `journalctl --user -u
  kimai -b`; missing user bus → `loginctl enable-linger $USER` (marker already written), then
  check `/etc/systemd/user/default.target.wants/`.
- **Re-run one install step** — no `--step` exists. Boot the ISO, mount and chroot (section 9),
  then repeat it: step 9 `pacman -S --needed --noconfirm <pkgs>`; step 11
  `install -Dm755 /root/gate/gate.py /usr/local/bin/kimrity-gate` and
  `/root/kimscanning/kimscan` → `/usr/local/bin/kimscan`; step 12 copy
  `/root/systemd/user/*.service` → `/usr/lib/systemd/user/` plus the `default.target.wants`
  symlinks. Step 12 also installs the three `hardening/` drop-ins (sysctl, sshd, audit identity);
  `dotfiles/nftables.conf` is never applied — change its `define SSH_SRC` (QEMU NAT `10.0.2.2`)
  to your LAN before enabling it on real hardware.

## 9. Recovery

Boot the live ISO, then mount the installed subvolumes (NVMe: `nvme0n1p2`/`p1`):

```sh
mount -o compress=zstd:3,noatime,subvol=@ /dev/vdX2 /mnt
mkdir -p /mnt/home /mnt/.snapshots /mnt/boot
mount -o compress=zstd:3,noatime,subvol=@home /dev/vdX2 /mnt/home
mount -o compress=zstd:3,noatime,subvol=@snapshots /dev/vdX2 /mnt/.snapshots
mount /dev/vdX1 /mnt/boot                    # ESP: limine.conf repairs
cp /etc/resolv.conf /mnt/etc/resolv.conf
mount --bind /dev /mnt/dev && mount -t proc proc /mnt/proc && mount -t sysfs sys /mnt/sys
arch-chroot /mnt
```

Fix inside the chroot (`pacman -Syu`, `mkinitcpio -P`, reinstall a package), then `exit`,
`umount -R /mnt`, `reboot`.

Rollback, as recorded in `install.sh`: (1) `snapper --ambit classic rollback N`; (2) boot the
read-write clone with `rootflags=subvol=@/.snapshots/N/snapshot` in `limine.conf`; (3) merge by
snapshotting the clone to FS_TREE (`@new`), renaming inside FS_TREE (`@` → `@.bak-damaged`,
`@new` → `@`) and setting the default subvolume. Never move content across subvolumes (btrfs
returns `EXDEV`); `@snapshots` is a sibling, so no snapshot-DB transplant. To start over, boot
the ISO and run `install.sh` again (it erases the disk).

## 10. Verifying an ISO before shipping

```sh
./tools/verify-iso.sh                  # newest in iso-out/; or pass a path
```

Runs as your user (xorriso + unsquashfs, no root, no loop mount) and exits 1 on any of its 19
checks: ISO ≤ 1.4 GB; squashfs extractable; 13 payload comparisons byte-identical to the repo
(`install.sh`, `hyprland.lua`, `gate.py`, `kimai`, `kimlogpipe` + `rules.yaml`, `kimscan`,
`en.yaml`, both user units, audit rules, plus the live `kimscan`/`en.yaml`); `/usr/local/bin/kimscan`
is `755`; motd says `installer (12 steps`; `HOSTNAME="kimrity"`; no Malay stopwords.

### Prove an install end to end (QEMU, no risk to the host)

`verify-iso.sh` proves the ISO *contains* the repo. It does not prove the ISO *installs*. That is
what `tools/qemu-install-test.sh` is for — a blank 24 GiB disk, the live ISO, the installer driven
through the QEMU monitor, then a real boot of the installed system:

```sh
./tools/qemu-install-test.sh install   # blank disk -> installer -> 12/12 -> password -> SSH key -> poweroff
./tools/qemu-install-test.sh boot      # same disk, no ISO -> waits for SSH to come up
```

Requires `qemu-system-x86_64`, `edk2-ovmf`, `socat`, `tesseract`, `imagemagick`, `python3`, `curl`.
Nothing runs as root and the host disks are never touched (the target is a file). Useful overrides:
`BASE` (scratch dir), `ISO`, `DISK`, `SSH_PORT`, `VM_MEM_MB`, `VM_CPUS`, `WHEELS_DIR` (local pip
wheelhouse for semgrep) — the defaults pick the newest ISO in `iso-out/` and a temp directory.

After `boot` succeeds, the health checks run *inside* the installed system:

```sh
scp -P <SSH_PORT> -i "$BASE/vmkey" tools/verify-installed.sh hayqal@127.0.0.1:~/verify-installed.sh
ssh -p <SSH_PORT> -i "$BASE/vmkey" hayqal@127.0.0.1 'bash ~/verify-installed.sh'   # 66 checks
```

The reference run (17 Nov, Build 14): install `Done` on a blank 24 GiB disk, boot with no ISO in
~15 s, desktop up, **66/66** checks (RAM 686 MiB, disk 2740 MB), `systemctl reboot`, `boot_id`
changed, SSH back in ~6 s, **66/66 again** with `systemctl --failed` and `--user --failed` both 0,
boot **7.804 s**. Hardening was proven inside the installed system, not assumed: 22 audit rules loaded
(`auditctl -l`), `PasswordAuthentication no`, `kptr_restrict=2`.
