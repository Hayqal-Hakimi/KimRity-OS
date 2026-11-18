#!/usr/bin/env bash
# verify-installed.sh — health check for a KimRity machine that is already
# installed and booted. Read-only: it inspects, it does not change anything.
#
# Why: install.sh proves the install ran; this proves the system is actually
# usable afterwards (desktop processes alive, portals wired, audio sink there,
# clipboard and screenshot working, no failed units). Run it after a fresh
# install, after a reboot, and after any upgrade.
#
# Usage: ./verify-installed.sh          # as the desktop user (some checks note-only)
#        sudo ./verify-installed.sh     # adds the root-only checks
#
# Exit code: 0 = every blocking check passed, 1 = at least one FAIL.
set -u

# Over SSH there is no WAYLAND_DISPLAY / HYPRLAND_INSTANCE_SIGNATURE, so grim,
# wl-copy and hyprctl would fail for a reason that has nothing to do with system
# health. Point them at the running session before checking anything.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -d "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" ]; then
  wl=$(ls -1 "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-* 2>/dev/null | head -1)
  [ -n "$wl" ] && export WAYLAND_DISPLAY=$(basename "$wl")
fi
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  sig=$(ls -1 "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/hypr 2>/dev/null | head -1)
  [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

# A root shell cannot see a desktop session: `systemctl --user` has no bus,
# HOME is /root (so ~/.bash_profile is the wrong file), XDG_RUNTIME_DIR points
# at /run/user/0, and pipewire/clipboard/grim only exist in the logged-in user's
# session. Running as root therefore reported 17 bogus failures (found 17 Nov).
# Instead of failing, drop to the desktop user and re-run: `sudo verify-installed.sh`
# then means the same thing as running it as yourself.
if [ "$(id -u)" -eq 0 ] && [ "${KIMRITY_DROPPED:-0}" != 1 ]; then
  target=${KIMRITY_USER:-$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NF {print $3; exit}')}
  if [ -z "$target" ]; then
    printf '  RUN AS THE DESKTOP USER, not root (no active session found)\n' >&2
    printf '  sudo is only needed for: sudo -E kimscan posture\n' >&2
    exit 2
  fi
  script=$(readlink -f "$0")
  # Quote each argument: an unquoted $* merges "two words" into two arguments.
  cmd="KIMRITY_DROPPED=1 XDG_RUNTIME_DIR=/run/user/$(id -u "$target") exec bash $(printf '%q' "$script")"
  for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
  exec su -l "$target" -c "$cmd"
fi

pass=0; fail=0
ok()   { printf '  OK    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '  ..    %s\n' "$1"; }

echo "== 1. identity =="
h=$(hostnamectl --static 2>/dev/null || cat /etc/hostname)
[ "$h" = "kimrity" ] && ok "hostname is kimrity" || bad "hostname is $h (expected kimrity)"

echo "== 2. zram swap =="
if [ -e /dev/zram0 ]; then ok "/dev/zram0 exists"; else bad "/dev/zram0 missing"; fi
alg=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null)
case "$alg" in *"[zstd]"*) ok "compression algorithm is zstd" ;; *) bad "comp algorithm: ${alg:-unreadable}" ;; esac
# zram-generator computes min(ram/2, 4096) from MemTotal in MiB and rounds to
# whole MiB, while /proc/meminfo is in kB — an exact byte compare fails by a few
# MiB (it reported "850 MiB, expected 850 MiB"). Compare with 10% tolerance.
zsize=$(awk '/MemTotal/{half=$2/2/1024; printf "%d", (half < 4096 ? half : 4096)}' /proc/meminfo)
dsize=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
dmib=$((dsize / 1024 / 1024))
if [ "$zsize" -gt 0 ] && [ "$dmib" -ge $((zsize * 9 / 10)) ] && [ "$dmib" -le $((zsize * 11 / 10)) ]; then
  ok "zram disksize ${dmib} MiB matches min(ram/2,4096) = ${zsize} MiB (10% tolerance)"
else
  bad "zram disksize ${dmib} MiB, expected ~${zsize} MiB"
fi
systemctl is-active --quiet systemd-zram-setup@zram0.service \
  && ok "systemd-zram-setup@zram0.service active" || bad "systemd-zram-setup@zram0.service not active"
swapon --show=NAME,TYPE,SIZE --noheadings 2>/dev/null | grep -q zram0 \
  && ok "zram0 is in use as swap" || bad "zram0 not in swap"

echo "== 3. autologin + session =="
EXPECT_USER=${KIMRITY_USER:-$(id -un)}
systemctl show getty@tty1.service -p ExecStart 2>/dev/null | grep -q -- "--autologin $EXPECT_USER" \
  && ok "getty@tty1 autologins $EXPECT_USER" || bad "getty@tty1 has no autologin"
grep -q 'tty1' "$HOME/.bash_profile" 2>/dev/null \
  && ok "~/.bash_profile starts Hyprland on tty1 only" || bad "~/.bash_profile guard missing"
pgrep -x Hyprland >/dev/null && ok "Hyprland is running" || bad "Hyprland is not running"
if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
  note "hyprctl: $(hyprctl version 2>/dev/null | head -1)"
fi
pgrep -x waybar >/dev/null && ok "waybar running" || bad "waybar not running"

echo "== 4. KimAI / KimLogPipe =="
for u in kimai kimlogpipe; do
  systemctl --user is-active --quiet "$u" && ok "user unit $u active" || bad "user unit $u not active"
done
command -v notify-send >/dev/null && ok "notify-send present (libnotify)" || bad "notify-send missing"

echo "== 5. KimScanning =="
command -v kimscan >/dev/null && ok "kimscan on PATH" || bad "kimscan missing"
[ -x /usr/local/bin/kimscan ] && ok "/usr/local/bin/kimscan is executable" || bad "/usr/local/bin/kimscan not executable"
[ -f /usr/local/share/kimscanning/rules/en.yaml ] && ok "en.yaml rules present" || bad "en.yaml rules missing"
grep -q 'SUPER + SHIFT + K' "$HOME/.config/hypr/hyprland.lua" 2>/dev/null \
  && ok "keybind SUPER+SHIFT+K in hyprland.lua" || bad "keybind SUPER+SHIFT+K missing"
# The install is fail-soft for both engines, so a skipped download would still
# print 66 OK lines. Build 17 makes their absence a FAIL.
command -v nuclei >/dev/null && ok "nuclei on PATH" || bad "nuclei missing (web scans will flag it)"
command -v semgrep >/dev/null && ok "semgrep on PATH" || bad "semgrep missing (SAST rule class disabled)"
out=$(kimscan posture --json 2>/dev/null || kimscan posture 2>/dev/null)
if [ -n "$out" ]; then
  ev=$(printf '%s' "$out" | grep -c 'evaluated' || true)
  note "kimscan posture produced output ($(printf '%s' "$out" | wc -l) lines)"
else
  bad "kimscan posture printed nothing"
fi

echo "== 6. budgets =="
boot=$(systemd-analyze 2>/dev/null | sed -n 's/.*= \([0-9.]*s\).*/\1/p' | head -1)
note "boot (firmware+loader+kernel+userspace): ${boot:-unknown}"
ram=$(free -m | awk '/^Mem:/{print $3}')
note "RAM used now: ${ram} MiB (budget <= 900)"
[ "${ram:-9999}" -le 900 ] && ok "RAM within budget" || bad "RAM ${ram} MiB over budget"
disk=$(df --output=used -BM / | tail -1 | tr -dc '0-9')
note "disk used: ${disk} MB (budget <= 5000)"
[ "${disk:-9999}" -le 5000 ] && ok "disk within budget" || bad "disk ${disk} MB over budget"

echo "== 7. bootloader =="
if [ -f /boot/EFI/BOOT/limine.conf ]; then
  ok "limine.conf written by installer"
  grep -q '^/Windows' /boot/EFI/BOOT/limine.conf \
    && bad "Windows entry written but bootmgfw.efi is absent (test disk)" \
    || ok "no Windows entry (bootmgfw.efi absent, as designed)"
  note "timeout: $(sed -n 's/^timeout: *//p' /boot/EFI/BOOT/limine.conf | head -1)"
else
  bad "/boot/EFI/BOOT/limine.conf missing"
fi

echo "== 8. daily-driver health =="
failed=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
[ "$failed" -eq 0 ] && ok "no failed system units" || { bad "$failed failed system unit(s)"; systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/        /'; }
ufailed=$(systemctl --user --failed --no-legend --plain 2>/dev/null | wc -l)
[ "$ufailed" -eq 0 ] && ok "no failed user units" || { bad "$ufailed failed user unit(s)"; systemctl --user --failed --no-legend --plain 2>/dev/null | sed 's/^/        /'; }

systemctl is-active --quiet NetworkManager && ok "NetworkManager active" || bad "NetworkManager not active"
systemctl --user is-active --quiet pipewire && ok "pipewire (user) active" || bad "pipewire (user) not active"
systemctl --user is-active --quiet wireplumber && ok "wireplumber (user) active" || bad "wireplumber (user) not active"
systemctl --user is-active --quiet xdg-desktop-portal-hyprland \
  && ok "xdg-desktop-portal-hyprland active" || bad "xdg-desktop-portal-hyprland not active"

for proc in waybar mako hypridle; do
  pgrep -x "$proc" >/dev/null && ok "$proc running" || bad "$proc not running"
done
pgrep -x qs >/dev/null && ok "quickshell (qs) running" || note "qs not running (Quickshell menu may be closed)"
pgrep -f hyprpolkitagent >/dev/null && ok "hyprpolkitagent running" || bad "hyprpolkitagent not running (no auth dialogs)"
pgrep -x wl-paste >/dev/null && ok "clipboard watcher running" || bad "wl-paste watcher not running"

for tool in kitty firefox yazi grim slurp wl-copy cliphist notify-send playerctl wpctl; do
  command -v "$tool" >/dev/null && ok "$tool present" || bad "$tool missing"
done

[ -d /var/log/journal ] && ok "journald is persistent (/var/log/journal)" || bad "journald is volatile"
mountpoint -q /home && ok "/home is a separate subvolume" || note "/home not a separate mount"
snapper list-configs 2>/dev/null | grep -q root && ok "snapper config 'root' present" || note "no snapper config 'root'"
systemctl list-timers --no-legend 2>/dev/null | grep -q snapper && ok "snapper timers scheduled" || note "snapper timers missing"

echo "== 9. session environment (portals, user units) =="
uenv=$(systemctl --user show-environment 2>/dev/null)
grep -q '^WAYLAND_DISPLAY=' <<<"$uenv" && ok "systemd user env has WAYLAND_DISPLAY" \
  || bad "systemd user env has no WAYLAND_DISPLAY (dbus-update-activation-environment missing)"
grep -q '^XDG_CURRENT_DESKTOP=Hyprland' <<<"$uenv" && ok "XDG_CURRENT_DESKTOP=Hyprland exported" \
  || bad "XDG_CURRENT_DESKTOP not exported (portal picks the wrong backend)"
# A missing session bus is silent: notifications, portals and every GTK dialog
# still "work" but nothing can talk to each other. tty1 autologin starts
# Hyprland straight from bash_profile, so this is the check that catches it.
if command -v busctl >/dev/null 2>&1 && busctl --user status >/dev/null 2>&1; then
  ok "session D-Bus reachable (busctl --user)"
else
  bad "no session D-Bus (notifications/portals will fail silently)"
fi
grep -q '^DBUS_SESSION_BUS_ADDRESS=' <<<"$uenv" && ok "DBUS_SESSION_BUS_ADDRESS in the user manager" \
  || note "DBUS_SESSION_BUS_ADDRESS not in systemd user env"
loginctl show-user "$EXPECT_USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' \
  && ok "linger enabled (user units start without login)" || bad "linger not enabled"
for u in kimai kimlogpipe; do
  systemctl --user is-enabled --quiet "$u" && ok "user unit $u enabled at boot" || bad "user unit $u not enabled"
done

echo "== 10. hardening actually applied =="
[ -f /etc/sysctl.d/90-hardening.conf ] && ok "sysctl drop-in installed" || bad "sysctl drop-in missing (shipped but not installed)"
[ "$(sysctl -n kernel.kptr_restrict 2>/dev/null)" = 2 ] && ok "kernel.kptr_restrict=2 live" || bad "kernel.kptr_restrict not 2"
[ -f /etc/ssh/sshd_config.d/10-hardening.conf ] && ok "sshd drop-in installed" || bad "sshd drop-in missing"
sshd -t >/dev/null 2>&1 && ok "sshd config valid (sshd -t)" || note "sshd -t needs root or reported an error"
grep -qs '^PasswordAuthentication no' /etc/ssh/sshd_config.d/*.conf && ok "password auth disabled" || note "password auth still allowed"
[ -f /etc/audit/rules.d/kimrity.rules ] && ok "audit rules installed" || bad "audit rules missing"
auditctl -l 2>/dev/null | grep -q etc_watch && ok "audit rules loaded (etc_watch)" || note "audit rules not loaded yet"

echo "== 11. daily basics actually work =="
route=$(ip route show default 2>/dev/null | head -1)
[ -n "$route" ] && ok "default route present" || bad "no default route"
# Gateway is read from the default route, not hardcoded to the QEMU NAT address:
# on real hardware 10.0.2.2 does not exist and the check would lie.
gw=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$route")
if [ -n "$gw" ]; then
  ping -c1 -W2 "$gw" >/dev/null 2>&1 && ok "gateway reachable ($gw)" || note "gateway $gw ping failed (ICMP may be filtered)"
else
  note "no gateway in the default route (link-local setup?)"
fi
sink=$(wpctl status 2>/dev/null | grep -c 'Sinks:')
[ "$sink" -ge 1 ] && ok "audio sink enumerated" || bad "no audio sink (pipewire/wireplumber)"
printf 'kimrity-clip-test' | wl-copy 2>/dev/null && [ "$(wl-paste 2>/dev/null)" = 'kimrity-clip-test' ] \
  && ok "clipboard round-trip works" || bad "clipboard round-trip failed"
shot=$(mktemp -u /tmp/shot-XXXX.png)
grim "$shot" >/dev/null 2>&1 && [ -s "$shot" ] && ok "grim captured a screenshot ($(stat -c%s "$shot") bytes)" || bad "grim could not capture"
rm -f "$shot"
command -v firefox >/dev/null && ok "firefox: $(firefox --version 2>/dev/null | head -1)" || bad "firefox missing"
command -v yazi >/dev/null && ok "yazi present ($(yazi --version 2>/dev/null | head -1))" || bad "yazi missing"

echo
echo "  boot_id: $(cat /proc/sys/kernel/random/boot_id)  uptime: $(uptime -p 2>/dev/null)"
echo "  Pass: $pass  Fail: $fail"
[ "$fail" -eq 0 ]
