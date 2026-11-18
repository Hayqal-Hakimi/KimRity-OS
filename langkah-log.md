# Log Langkah — OS Security + AI

*Dipaste ke chatbot (Prompt A + 20 baris terakhir) bila mula chat baharu. Satu entri setiap sesi.*

---

## 2026-10-14 (sesi 2 — selepas had chatbot reset)

### Buat

1. **Muat turun ISO Arch** (blocked sebelum ini: kau jumpa `.sig` sahaja, bukan fail ISO)
   - Fail ISO sebenar ada di bawah **HTTP Direct Downloads → senarai mirror** (setiap mirror = folder), bukan dalam blok "Checksums and signatures"
   - Mirror `kernel.org` terlalu perlahan (270 KB/s) → tukar ke **mirror.sg.gs** (20 MB/s), siap 76 saat
   - Lokasi: `~/vm/iso/archlinux-2026.10.01-x86_64.iso` · `.sig` disalin ke situ (asal kekal di `~/Downloads`)
2. **Sahkan ISO**
   - Saiz: `1640497152` bait (padan tepat dengan saiz rasmi)
   - `sha256sum -c` → **OK** (`684ded26c63240ff4a41e8c25ee84ea6da233f557364821f13d12c2b0a9059a5`)
   - `gpg --verify` → **Good signature from "Pierre Schmitz <pierre@archlinux.org>"**, cap jari `3E80 CA1A 8B89 F69C BA57 D98A 76A5 EF90 5444 9A5C` (padan `0x54449A5C` pada halaman Arch)
   - Amaran "not certified with a trusted signature" = **normal** (kunci belum diperakui dalam keyring sendiri)
3. **Boot ISO dalam VM ujian** — `~/vm/ujian/`
   - Skrip: `./mula.sh /home/hayqal/vm/iso/archlinux-2026.10.01-x86_64.iso`
   - Konfigurasi: `q35` · `-accel kvm` · `-cpu host` · 2 vCPU · **2560 MB** · OVMF 4m (CODE read-only + salinan sendiri `OVMF_VARS.fd`) · `disk.qcow2` 40 GiB virtio · net user-mode · virtio-vga · GTK
   - Hasil: **boot berjaya** → `archiso login: root (automatic login)` → `[root@archiso ~]#`
4. **Enam semakan asas dalam guest — SEMUA LULUS**

| Semakan | Keputusan |
|---|---|
| `systemd-detect-virt` | `kvm` |
| `/sys/firmware/efi` | wujud → **UEFI: YA** |
| `lsblk` | `vda` 40G disk · `sr0` 1.5G rom (ISO) · **`sr1` 1024M rom — belum dijelaskan** |
| `ip -4 -br addr` | `enp0s1 UP 10.0.2.15/24` (NAT) |
| `timedatectl` | jam + NTP tepat |
| `ping -c2 archlinux.org` | 2 diterima, 0% hilang, 27 ms |

### Bukti / nilai penting

- Kernel guest `7.2.7-arch1-1` vs host `7.2.5-3-omarchy` → host memang ketinggalan
- Mirror host (`stable-mirror.omarchy.org`, channel **stable**) ialah cermin **terpaku**: ia masih menyajikan versi tepat dalam DB pacman host (`qemu-desktop-11.1.1-1` → HTTP 200; versi upstream `11.1.2-1` → 404). Jadi `pacman -S` di host boleh jalan **tanpa** upgrade penuh
- Host: upgrade penuh terakhir **19 Sep** (masa install), DB mirror **9 Sep** → ~5 minggu di belakang. **Tidak menyekat** kerja VM

### Belum

- **Keputusan pelan partisi guest** — pakej **A / B / C** + **manual atau `archinstall`** (cadangan Hermes: **B, manual**)
- Output `lsblk -o NAME,SIZE,TYPE,LABEL` — untuk pastikan `sr1 1024M` itu apa
- Kemudian: partisi → mkfs → pacstrap → chroot → bootloader → reboot dalam VM

### Blocker

- Tiada. `disk.qcow2` masih **kosong** (196 KiB) — belum ada apa-apa dipasang, jadi semuanya boleh diulang/dipadam.

---

## 2026-11-15 — Fasa 1: jadikan KimRity layak jadi OS harian

**Skop Fasa 1:** buktikan sistem sedia ada boleh dipasang, boot, dipakai kerja biasa, dan kekal sihat selepas reboot. Tiada ciri baharu.

### Apa dibaik

| Fail | Perubahan | Bukti |
|---|---|---|
| `dotfiles/hypr/hyprland.lua` | `SUPER + W` = Close window (ganti `SUPER + Q`, yang dibiarkan bebas untuk "quit" app); `SUPER + L` kini panggil `~/.local/bin/lock` | `luac -p` lulus; hos `hyprctl binds` tiada `modmask 64 + key Q` |
| `dotfiles/local-bin/lock` (baharu) | Skrin lock bergantung pada `passwd -S`: `P` → `hyprlock`, selain itu notifikasi "no password set" | `sh -n`; logik diuji pada akaun hos (`P`) |
| `dotfiles/hypr/hypridle.conf` | `lock_cmd` + `before_sleep_cmd` guna `lock`, bukan `hyprlock` terus | — |
| `dotfiles/local-bin/powermenu` | Menu "Lock" guna `lock` | `sh -n` |
| `dotfiles/local-bin/workspace-launch` | Pepijat `IFS='|'`: baris `kitty -e bash -lc 'suricata … | head'` dipecah pada `|` dalam arahan → preset F2 mati. Kini 4 medan + gabung semula | `--dry-run` sebelum/selepas: baris 2 F2 hidup |
| `dotfiles/local-bin/menu-toggle` | Guard `qs` (SUPER+D senyap sebelum ini), `-n` elak dua panel, poll `openMenu` 30×0.2 s (maks ~6 s) bukan satu `sleep 0.5` | shim `qs` palsu: jawab, lambat, dan tidak menjawab |
| `dotfiles/local-bin/cliphist-menu` | Guard `cliphist`/`wl-copy`, sejarah kosong tidak buka tetingkap kosong, decode ke fail dulu (dulu boleh kosongkan clipboard sebenar) | shim cliphist kosong/berisi, tanpa wofi, tanpa wl-copy |
| `dotfiles/local-bin/screenshot` | Guard `grim`; nama fail unik (`-1`, `-2`) bila PRINT ditekan dua kali dalam saat sama | grim palsu, `HOME=/tmp` → dua fail berbeza |
| `dotfiles/local-bin/kimrity-menu` | Edit `hyprland.lua` (fail sebenar), bukan `hyprland.conf` yang tidak wujud; `mkdir -p ~/.config/nvim` sebelum nvim | `bash -n` |
| `dotfiles/local-bin/kimrity-tools` | Fail cache sementara guna `$$` (dua panel boleh tulis serentak), `find -L` (binari symlink seperti `sh`/`python3` dulu tercicir) | bina sejuk + cache: 4128 baris dua-dua kali |
| `dotfiles/local-bin/kimrity-flatpak` | `help` tidak lagi cetak `set -euo pipefail`; `list` beritahu bila flatpak tiada (dulu senyap, exit 0) | output `help`, `list` → rc1 |
| `dotfiles/local-bin/wallpaper` | Guard `swaybg` + notifikasi (dulu sesi hitam tanpa mesej) | shim tanpa swaybg → rc1 + notify |
| `install.sh` | `hardening/` yang selama ini **dihantar dalam ISO tetapi tidak pernah dipasang** kini dipasang di step 12: `/etc/sysctl.d/90-hardening.conf`, `/etc/ssh/sshd_config.d/10-hardening.conf`, `/etc/audit/rules.d/10-identity.rules` | simulasi chroot: `ssh-keygen -A` gagal → drop-in dikekalkan; `sshd -t` gagal → drop-in dibuang + warn; kedua-dua kali install tetap exit 0 |
| `install.sh` | `ssh-keygen -A` dalam chroot **sebelum** `sshd -t` — Arch jana host key pada boot pertama, jadi tanpa ini `sshd -t` gagal palsu dan drop-in SSH dibuang senyap | dua simulasi di atas |
| `install.sh` | `--no-password` + prompt `passwd` di hujung install (TTY sahaja); sebab: akaun tanpa password → `sudo` dan `hyprlock` tidak boleh authenticate | `--dry-run` cetak dua `[dry] arch-chroot /mnt passwd`; `--no-password` cetak warn |
| `install.sh` | `KIMRITY_PIP_FIND_LINKS` + `--trusted-host` untuk wheelhouse `http://`; semgrep/nuclei fail-soft (warn, teruskan); `trap` cetak `[x] step N/12 … failed at: cmd` + cadangan `arch-chroot` | simulasi pip stall → warn + terus; `--find-links http://… --trusted-host …` muncul dalam log |
| `install.sh` | `noatime` dalam `MOUNT_OPTS`; semakan fstab (`/`, `/home`, `/boot`, `subvol=/@`); auditd dipindah ke step 12 (pakej `audit` hanya ada selepas step 9); `pavucontrol` + `noto-fonts-emoji` + `xdg-desktop-portal-gtk` | `--dry-run` exit 0 |
| `tools/build-iso.sh` (baharu) | Satu arahan: sync → gate drift → mkarchiso → verify | build 13 |
| `tools/verify-installed.sh` (baharu) | 53 semakan kesihatan selepas boot (unit gagal, portal, audio, clipboard, grim, hardening, fstab, bajet) | dijalankan dalam guest |
| `README.md` (baharu, 213 baris) + `iso/README.md` | Manual operator: pasang, flag sebenar, checklist boot pertama, keybind, troubleshooting, recovery, dua "trap" (password, SSH key-only) | fakta disemak terhadap repo |

### Ujian yang dijalankan

- **Static:** `luac -p` untuk `hyprland.lua`, `bash -n`/`sh -n` untuk `install.sh`, semua `tools/*.sh` dan `dotfiles/local-bin/*` → 0 ralat.
- **Dry-run:** `./install.sh --disk /dev/vda --yes --efi --no-arsenal --dry-run` → exit 0, 22 tindakan dicetak, tiada cakera disentuh.
- **Ujian install Build 12 (sebelum pembaikan) → GAGAL di 11/12**, dan kegagalan itu sendiri berguna: `pip` menolak wheelhouse `http://10.0.2.2:8000` (`WARNING: … not a trusted or secure host and is being ignored` → `No matching distribution found for semgrep`). Langkah 1–11 lulus; ISO yang diuji masih membawa `install.sh` **lama** (tanpa fail-soft), jadi ia berhenti dan bukannya warn. Dua pepijat ditemui sebab ini: (a) `--trusted-host` wajib untuk wheelhouse http, (b) ujian mesti guna ISO yang baru dibina.

### Build 13 — ISO baharu selepas pembaikan

| Perkara | Hasil |
|---|---|
| Fail | `iso-out/kimrity-2026.11.15-x86_64.iso` |
| Saiz | 1,327,235,072 B (1265 MiB) — dalam bajet 1.4 GB |
| sha256 | `3a2607bb7a1a3c2c025a7e0f284d5b017b7e6c3e5fc865c0a6c99eb5263f8ce7` |
| Masa siap | 17:25:18 (mkarchiso `INFO: Done!`, xorriso 648064 sektor) |
| `tools/verify-iso.sh` | **19/19 lulus** (13 payload == repo, permission `kimscan` 755, motd 12 langkah, hostname `kimrity`, 0 stopword BM) |
| ISO lama | `kimrity-2026.11.14` dipadam (polisi satu ISO) — `iso-out/` kini satu fail |

Dua pepijat ditemui **semasa** build ini, kedua-duanya kelas "nilai hardcode":

1. **`tools/build-iso.sh` hardcode `sudo`.** Grant passwordless hos bersifat sementara (polkit);
   selepas luput, `sudo mkarchiso …` mati dengan `sudo: a terminal is required to read the password`
   dan build hilang. Dibetulkan: fungsi `as_root()` — cuba `sudo -n`, gagal → `pkexec`, jika dua-dua
   tiada → mesej jelas. `rm -rf "$WORK"` (dimiliki root) guna laluan yang sama.
2. **Ujian install pertama mati serta-merta**: `run-install-test.sh: line 47: t: unbound variable`.
   Sebab: dalam bash, `local pat=$1 t=${2:-300} … end=$(( $(date +%s) + t ))` mengisytiharkan **semua**
   nama `local` dahulu, jadi `t` masih belum bernilai ketika aritmetik dikira (dengan `set -u` = ralat).
   Dibetulkan: satu nama per baris. Corak sama tidak ada dalam repo (disemak dengan grep).

Kedua-duanya akibat nilai/cara yang ditanam berulang, bukan salah faham projek — sebab itu peraturan
"tiada hardcode" (skill `no-hardcoded-values`, `brainQ/decisions/tiada-hardcode-satu-sumber-kebenaran.md`)
dijadikan peraturan seluruh kerja pada hari yang sama.

**Dua lagi pepijat kelas sama (harness ujian, /var/tmp/opencode):**

3. `type12.py` simpan `SOCK = "/var/tmp/opencode/mon12.sock"` secara literal → setiap run dengan
   monitor lain mati `FileNotFoundError` walaupun VM sihat. Kini `MON` env (`os.environ.get`) dengan
   default `mon.sock`; `run-install-test.sh` menghantar `MON="$MON"`.
4. `waitfor.sh` sama: monitor `mon12.sock` + screendump `w.ppm` literal. Kini `MON`, `SHOT`, `BASE`
   env dengan default; diuji dengan nilai berbeza (`MON=/tmp/tiada.sock` → `TIMEOUT`, tiada crash).

### Ujian install segar — Build 13 (LULUS)

```
cd /var/tmp/opencode && DISK=…/testdisk13.img MON=…/mon13.sock SER=…/serial13.log \
  SSH_PORT=2224 ./run-install-test.sh install
```

| Semakan | Hasil |
|---|---|
| Boot ISO pada cakera kosong 24 GiB | `root@archlinux` muncul (OCR, 3 bingkai berturut) |
| `install.sh --disk /dev/vda --yes --efi --no-arsenal --no-password` | sampai **`12/12`** tanpa `[x] step` |
| Baris penutup | `Done` dikesan |
| Password ujian + kunci SSH disuntik | `hayqal:kimritytest` + `vmkey.pub` → `/mnt/home/hayqal/.ssh/authorized_keys` |
| `umount -R /mnt && poweroff -f` | VM mati bersih, `EXIT=0` |

Ini kali pertama installer sampai 12/12 dalam VM. Kegagalan Build 12 (pip menolak wheelhouse `http://`)
tidak berulang kerana `--trusted-host` kini dihantar automatik.

### Audit "tiada hardcode" ke atas kerja **sebelum** peraturan ini wujud

Dijalankan selepas peraturan 15 Nov dijadikan standard. Kaedah: grep sistematik untuk
(a) `/home/<nama>` dan nama pengguna, (b) port/IP/hos, (c) nama fail bertarikh/berversi,
(d) saiz/resolusi/amaun khusus mesin, (e) path tetap dalam unit/skrip, (f) `sudo` mentah.

**Dibaiki (benar-benar berisiko):**

| Fail | Nilai ditanam | Ganti | Bukti |
|---|---|---|---|
| `tools/verify-installed.sh` | `ping 10.0.2.2` (gateway QEMU) | gateway dibaca dari `ip route show default` | hos: dikesan `192.168.0.1`, bukan 10.0.2.2 |
| `dotfiles/nftables.conf` | `ip saddr 10.0.2.2 tcp dport 22` | `define SSH_SRC` / `define SSH_PORT` di atas fail | `nft -c -f` sebagai root → rc=0 |
| `dotfiles/quickshell/kimrity/shell.qml` | fallback `"/home/hayqal"` | `HOME` → `/home/`+`USER` | QML: `Quickshell.env` |
| `dotfiles/local-bin/screenshot` | `$HOME/Pictures` tetap | `KIMRITY_SHOT_DIR` (default `$HOME/Pictures`) | `sh -n` |
| `install.sh` | `LOCALE`/`KEYMAP` tanpa override | flag `--locale`, `--keymap`; nilai **resolved** dicetak sebelum apa-apa disentuh | dry-run `--keymap de --locale de_DE.UTF-8` → `locale=de_DE.UTF-8 keymap=de`; default `en_US.UTF-8`/`us` |
| `tools/build-iso.sh` | `sudo` (dua tempat) | `as_root()`: `sudo -n` → `pkexec` | build 15 Nov mati kerana ini |
| `tools/vm-on-vt.sh` | `2223`, `1792`, `-smp 2`, `/var/tmp/...OVMF*` | `VM_SSH_PORT`, `VM_MEM_MB`, `VM_CPUS`, `VM_SOCK`, `VM_OVMF_VARS/CODE` + semakan OVMF + laluan root | `bash -n`; override diuji |

**Sengaja DIBIARKAN (dan sebabnya):**

- `install.sh` default `USERNAME=hayqal`, `HOSTNAME=kimrity`, `USER_UID=1000` → sudah ada `--user`/`--hostname`; default yang boleh ditukar.
- `hyprland.lua` `Virtual-1 / 1360x768` → hanya terpakai pada output bernama itu (VM); monitor sebenar guna `preferred`; sudah dikomen.
- `kimlogpipe/test/run_tests.sh` (banyak `hayqal`) → teks audit **sintetik** untuk ujian parser; tiada kesan pada sistem sebenar.
- `gate/test/uji-v2.sh` (`:8080`, `:3306`, `/root/webtest`) → fixture ujian, dijalankan sedar sebagai root.
- `nmap --top-ports 1000` → parameter alat, bukan ciri mesin.
- Unit systemd `ExecStart=/usr/local/bin/…` → lokasi pasang yang didokumen; kimai/kimlogpipe baca env override.
- `zram-size = min(ram / 2, 4096)` → formula, bukan nilai mesin.

Kesimpulan: tiada nilai bertarikh/berversi dalam skrip (semua guna glob), dan tiada rahsia dalam kod.
Baki risiko terbesar yang sudah ditutup ialah gateway palsu dalam skrip kesihatan — ia akan melaporkan
"gateway OK" secara salah pada hardware sebenar.

### Ujian boot + reboot + skrin lock — Build 13 (LULUS)

| Semakan | Bukti |
|---|---|
| Boot dari cakera tanpa ISO | Limine → `Boot0002 "UEFI Misc Device"` → autologin tty1 → Hyprland; SSH masuk (`SSH_OK`, hostname `kimrity`) |
| Desktop | Waybar hidup: workspace `1`, jam `17:40 Sun 15 Nov`, `CPU 2% RAM 34%`, LAN; wallpaper solid (`desktop13.jpg`) |
| `tools/verify-installed.sh` | **66 OK, 0 FAIL** merentas 11 seksyen: identity, zram, autologin+sesi, kimai/kimlogpipe, kimscanning, budget (footprint/unit), bootloader, kesihatan harian, persekitaran sesi (D-Bus, portal, unit user), hardening benar-benar dipasang, asas harian (route+gateway, audio sink, clipboard round-trip, grim) |
| `sudo` dengan password | `sudo -S -k id -u` → `0` (akaun boleh admin, bukan `!` dalam shadow) |
| Skrin lock (bukan sekadar semakan) | `~/.local/bin/lock` → hyprlock hidup → skrin "KimRity / password" muncul → taip password → **terbuka** (`hyprlock` keluar) |
| Reboot sebenar | `systemctl reboot` → SSH balik ~8 s → `boot_id` **berubah** `1975b3c2` → `8c265987` |
| Selepas reboot | `verify-installed.sh` → **66 OK, 0 FAIL**; `systemctl --failed` = **0**; `systemctl --user --failed` = **0** |

**Satu kelemahan harness dibetulkan:** mod `boot` dalam `run-install-test.sh` menunggu teks
`login:|Hyprland|kimrity` di skrin. Sistem autologin **tidak pernah** memaparkan teks itu, jadi ujian
akan gagal pada boot yang sihat. Kini ia mengundi SSH sebagai isyarat kesediaan (maks 5 min), skrin
hanya untuk diagnostik. Pengajaran: jangan guna OCR sebagai penentu keadaan bila ada isyarat tepat
(SSH/exit code).

**Satu lagi pepijat semakan sendiri dibetulkan:** `disksize 850 MiB, expected 850 MiB` — perbandingan
tepat antara kB (`/proc/meminfo`) dan MiB (zram-generator) sentiasa gagal; kini toleransi 10%.

### Harness ujian dijadikan self-contained (17 Nov)

`tools/qemu-install-test.sh` pada awalnya bergantung pada `type12.py` yang hanya wujud dalam
folder sementara mesin ini — jadi skrip itu **tidak boleh dijalankan** oleh orang lain walaupun ia
sudah masuk repo (bukti yang tidak boleh diulang = bukan bukti).

- Tambah `tools/qemu-type.py`: teks → `sendkey`, monitor dari `MON`/`--monitor`, **tiada default**
  (default yang salah itulah punca `FileNotFoundError: mon12.sock` dulu). Diuji dengan socket palsu:
  `"Hi-Q!"` → `shift-h | i | minus | shift-q | shift-1`.
- Nilai guest dijadikan pemboleh ubah: `TARGET_DISK` (`/dev/vda`), `TEST_USER`, `TEST_PASS`
  (sebelum ini `hayqal`/`/dev/vda` ditanam dalam perintah yang ditaip).
- Mod `boot` menolak jalan jika VM lain sudah memakai cakera ujian yang sama.

### ISO akhir — kenapa dibina tiga kali (jujur)

| Cubaan | Keputusan | Sebab |
|---|---|---|
| Build 13 (`11.15`, sha `3a2607bb…`) | **lulus** verify 19/19 + ujian install/boot/reboot penuh | tetapi dibina **sebelum** audit hardcode + harness masuk repo |
| Cuba semula #1 | **dihentikan** | satu pembetulan komen masuk semasa squashfs sedang berjalan → ISO tidak lagi sama dengan repo, `verify-iso.sh` akan gagal pada perbandingan payload |
| Cuba semula #2 | **dihentikan** | ditemui harness bergantung pada `type12.py`; lebih murah betulkan dahulu daripada bina ISO yang tidak boleh diuji semula |
| Build 14 (`11.17`) | lihat di bawah | repo dibekukan dahulu, kemudian bina sekali sahaja |

### Pusingan kedua audit hardcode (17 Nov) — 4 nilai lagi

Dijumpai semasa menyemak ISO sebelum dibekukan. Semua ini masuk payload yang **dipasang**
atau skrip yang mesti boleh dijalankan di mesin lain.

| Fail | Masalah | Pembetulan | Ujian |
|---|---|---|---|
| `hardening/audit/10-identity.rules` | `-w /home/hayqal/.ssh/` — auditd **terima** watch pada path yang tidak wujud dan kemudian memantau **tiada apa-apa** (kegagalan senyap) | templat `__USER_HOME__`, diganti `install.sh` dengan `/home/$USERNAME` semasa pasang, dengan `info` yang menyebutnya | `grep __USER_HOME__` selepas install (uji dalam VM) |
| `tools/build-iso.sh` | log ditulis ke `/var/tmp/opencode/…` (folder khusus mesin ini); `df` juga semak `/var/tmp` secara tetap | `KIMRITY_LOG_DIR` (default `${TMPDIR:-/tmp}/kimrity-build`); ruang diperiksa pada `dirname $WORK` | build yang menggunakan skrip ini |
| `tools/vm-on-vt.sh` | `VM_SOCK`/`VM_OVMF_VARS` default ke `/var/tmp/opencode` | `VM_RUN_DIR` (default `${TMPDIR:-/tmp}/kimrity-vt`) + mesej ralat yang beri arahan `cp …OVMF_VARS.4m.fd` | `VM_RUN_DIR=/tmp/vt-test` → ralat betul, tiada VM bermula |
| `hardening/sshd/10-hardening.conf` | komen memasang nama peribadi dalam fail yang dipasang (`hayqal + root`) | "the install user + root" | — |

Prinsip yang berulang: nilai khusus mesin bukan sekadar "tak cantik" — ia boleh menjadi
**kegagalan senyap** (audit watch kosong) atau **build mati** (log dir tiada).

### Build 14 — ISO akhir dan bukti Fasa 1 (17 Nov)

| Perkara | Hasil |
|---|---|
| Fail | `iso-out/kimrity-2026.11.17-x86_64.iso` |
| Saiz | 1,327,243,264 B (1.24 GiB) — dalam bajet 1.4 GB |
| sha256 | `864a3a9b103304b06a4083c4c4796a123743fc350abea8a8e8e8b4952f694c86` |
| `tools/verify-iso.sh` | **19/19**, `EXIT=0` |
| ISO lama | `kimrity-2026.11.15` dipadam selepas 11.17 disahkan — `iso-out/` satu fail |

Ujian penuh pada ISO ini (QEMU, cakera maya **24 GiB kosong**, bukan cakera sebenar):

| Bukti | Hasil |
|---|---|
| Install | `install.sh` sampai `==> Done`; `semgrep installed`, `nuclei v3.11.1`, `hardening: 3/3 drop-ins` |
| Hardening **dalam sistem terpasang** | `placeholder=0 userpath=1 sshd=1 sysctl=ada` — templat `__USER_HOME__` betul-betul diganti; `auditctl -l` = **22 rules**, termasuk `-w /home/hayqal/.ssh -p wa -k ssh_keys`; `kptr_restrict=2 dmesg_restrict=1 ptrace_scope=1 syncookies=1`; `sshd -T` → `PasswordAuthentication no`, `PermitRootLogin prohibit-password` |
| Boot dari cakera (tanpa ISO) | SSH hidup **~15 s**, hostname `kimrity`, `boot_id 83c0e717…` |
| `tools/verify-installed.sh` | **66 OK, 0 FAIL**; RAM **686 MiB** (≤900), disk **2740 MB** (≤5000) |
| Reboot | `boot_id` `83c0e717` → `f7459a8c`; SSH balik **~6 s**; `systemctl --failed`=0 dan `--user --failed`=0; boot **7.804 s** (≤12 s) |
| Desktop | `grim` tangkapan 38,809 B sahaja diambil (Waybar + layer `wallpaper` pid 428); Hyprland **0.57.2** |

Dua kelemahan **alat ujian** ditemui oleh ujian ini sendiri (bukan oleh bacaan kod):

1. **Harness menunggu teks yang sudah skrol keluar.** `qemu-install-test.sh` menunggu `12/12`,
   tetapi baris itu hilang dari skrin apabila ringkasan 12 langkah dicetak — jadi ia menunggu 25
   minit pada pemasangan yang **sudah siap** (`==> Done` terpapar, prompt root menunggu). Kini
   menunggu `Done` (atau `[x] step` bila gagal). Pelajaran sama seperti mod `boot`: tunggu **isyarat
   akhir keadaan**, bukan teks yang kebetulan melintas.
2. **`verify-installed.sh` melaporkan 17 FAIL palsu bila dijalankan sebagai root.** Shell root tiada
   bas `systemctl --user`, `HOME=/root` (fail `~/.bash_profile` yang salah), `XDG_RUNTIME_DIR` menunjuk
   `/run/user/0`, dan pipewire/clipboard/grim hanya wujud dalam sesi pengguna. Kini skrip **turun ke
   pengguna desktop dan menjalankan semula dirinya**; `sudo bash verify-installed.sh` memberi **66/66**
   yang sama seperti dijalankan sendiri.

**Jujur tentang urutan:** ISO 11.17 dibina **sebelum** dua pembetulan alat di atas. Salinan alat ujian
dalam ISO (`iso/airootfs/root/tools/`) jadi satu revisi di belakang repo; `iso/airootfs` sudah
disegerak semula selepas itu, jadi `sync-iso.sh --check` bersih. Ini **tidak** menjejaskan sistem yang
dipasang: `verify-installed.sh`/`qemu-install-test.sh` tidak dipasang ke cakera — ia dijalankan dari
hos melalui SSH/monitor. Build 15 (rebuild akan datang) akan membawa salinan yang sama.
`verify-iso.sh` tidak membandingkan alat harness (ia menyemak payload yang **dipasang**), jadi ISO
11.17 masih **19/19** selepas sync — dijalankan semula pada 22:56 untuk memastikan itu, bukan
menganggapnya.

**Pemerhatian pertama-log-masuk:** selepas install, skrin desktop ditutup oleh tetingkap Hyprland
sendiri (`class: hyprland-donate-screen`, tajuk "Hyprland Updated") — notis sekali-per-versi daripada
Hyprland, bukan daripada config KimRity. Ia boleh ditutup dengan "Thanks". Tidak disembunyikan dengan
windowrule kerana ia memaklumkan perubahan versi yang nyata; keputusan sama ada mahu menyembunyikannya
dibuat kemudian.

### Build 15 — audit penuh + tujuh pembetulan (18 Nov)

Build 15 bukan build kosmetik: ia hasil satu audit `ponytail-audit` ke atas `install.sh`,
`tools/`, `dotfiles/` dan `tests/`. Setiap penemuan diuji dengan arahan sebelum dipercayai,
dan setiap pembetulan diuji selepas ditulis. Diff sebenar (`git diff HEAD`, tanpa salinan ISO):
**+29 / −202 baris** — 189 daripadanya fail menu mati yang dibuang — dan satu fail baharu
`tests/part.sh` (18 baris). Bersih: **−173 baris**.

| # | Penemuan (kelas) | Pembetulan | Bukti |
|---|---|---|---|
| 1 | `nuclei` dimuat turun sebagai root tanpa semakan checksum | `NUCLEI_VERSION` + `NUCLEI_SHA256` dipin; `sha256sum -c` sebelum `unzip` | hash disahkan terhadap aset sebenar 44.0 MB; `OK` bila sepadan, `FAILED` + exit 1 bila satu bait diubah; dalam guest: `nuclei -version` → **v3.11.1** |
| 2 | Menu mati `kimrity-menu` (123 baris) + `dotfiles/wofi/` masih diselenggara, 0 pemanggil | kedua-duanya dipadam; `wofi` **pakej** kekal (powermenu `SUPER+V`, tiada `--conf`/`--style`) | `grep -rn wofi dotfiles/` → hanya `wofi --dmenu`; `unsquashfs -l` ISO → 13 fail `local-bin` (sama seperti repo), **0** `kimrity-menu`, tiada `dotfiles/wofi`; dalam guest: `kimrity-menu` TIADA, `~/.config/wofi` TIADA, `/usr/bin/wofi` ADA |
| 3 | Label langkah 12 menyembunyikan pemasangan hardening | label dinamakan semula: sysctl/sshd/audit disebut | `==> 12/12 KimAI + KimLogPipe live pipeline + hardening drop-ins (sysctl, sshd, audit)` muncul dalam dry-run dan install sebenar |
| 4 | `--locale` untuk locale tidak tersenarai gagal **senyap** | satu baris `grep -qx … \|\| echo … >>` selepas `sed` | `ms_MY.UTF-8` diaktifkan; `zz_ZZ.UTF-8` kini ditambah, bukan senyap |
| 5 | `su -c` membina baris dengan `$*` tidak di-quote | setiap argumen melalui `printf %q` | `"dua perkataan"` kekal satu argumen |
| 6 | Saiz cakera ujian hardcode `24G` | `DISK_SIZE` (default `24G`) + dicetak bersama laluan | `blank disk: /var/tmp/opencode/testdisk15.img (24G)` dalam log ujian |
| 7 | `part()` tiada ujian walaupun ia menentukan peranti yang diformat | `tests/part.sh` mengekstrak fungsi sebenar dari `install.sh` | **3/3** (vda→vda1, nvme0n1→nvme0n1p1, mmcblk0→mmcblk0p1) |

Semakan yang dijalankan, bukan diandaikan: `bash -n` semua skrip · `tests/part.sh` 3/3 ·
`install.sh --dry-run` pada `/dev/vda` → `vda1/vda2` dan pada `/dev/nvme0n1` → `nvme0n1p1/nvme0n1p2`
(exit 0 kedua-dua) · checksum nuclei dua hala · guard locale dua hala · 0 stopword Melayu dalam
fail yang dihantar (semakan `verify-iso.sh` §4) · `sync-iso.sh --check` bersih · 0 calon rahsia
dalam diff.

**Satu andaian saya sendiri yang salah, dan cara ia ditangkap:** saya menyangka
`echo '$NUCLEI_SHA256 …'` di dalam rentetan bertanda `"` akan sampai ke chroot sebagai teks
literal (dan akan mematikan pemasangan nuclei). Ujian menunjukkan sebaliknya — bash luar
mengembangkan pemboleh ubah itu dahulu, jadi hash sebenar yang sampai ke `sh -c`. Pembetulan
tidak diperlukan; yang diperlukan ialah ujian, bukan keyakinan.

#### ISO Build 15

| Perkara | Nilai |
|---|---|
| Fail | `kimrity-2026.11.18-x86_64.iso` (label `KIMRITY_202611`) |
| Saiz | 1,327,239,168 bait (1.24 GiB) |
| sha256 | `58970869596d9a7bf2c45e7b9897b39804591e06c3e123fa1a22e1fc162e5718` |
| `verify-iso.sh` | **19/19**, 0 gagal (`EXIT=0`) |

#### Ujian install + boot — Build 15 (LULUS)

| Peringkat | Hasil |
|---|---|
| Install (cakera kosong 24 GiB) | `==> Done`, tiada `[x] step`; nuclei v3.11.1 dimuat turun **dan disemak sha256**; semgrep dipasang dari wheelhouse 67 roda; `INSTALL_EXIT=0` |
| Boot dari cakera (tanpa ISO) | SSH hidup (isyarat kesediaan sebenar; autologin tty1 bermakna "login:" tidak pernah muncul) |
| `verify-installed.sh` | **66/66**, 0 gagal — RAM 620 MiB, disk 2.7 GB |
| Hardening dalam sistem terpasang | `sshd -T`: `PasswordAuthentication no`, `PermitRootLogin prohibit-password`, `PermitEmptyPasswords no`; `auditctl -l` **22** baris; sysctl `kptr_restrict=2 dmesg_restrict=1 ptrace_scope=1 tcp_syncookies=1` |
| Locale | `/etc/locale.conf` = `LANG=en_US.UTF-8`, `localectl` sama, login shell dapat `LANG`; `LANG` kosong dalam `ssh exec` bukan pepijat (bukan login shell) |
| Reboot | `boot_id` `0df943c3…` → `3bb5ccbc…`; SSH balik ~15 s; `verify-installed.sh` **66/66** sekali lagi; `--failed` 0 (sistem) / 0 (pengguna) |
| Masa boot | `systemd-analyze`: **11.938 s** (firmware 1.686 + loader 2.242 + kernel 0.822 + initrd 1.399 + userspace 5.787) pada boot pertama; **8.291 s** selepas reboot (userspace 2.686, `graphical.target` 2.381) |

Nota ujian: `BASE=/var/tmp/opencode` (wheelhouse sama seperti Build 14) dan
`DISK=/var/tmp/opencode/testdisk15.img` — **bukan** `/tmp`, kerana `/tmp` ialah tmpfs 3.9 GB
dan cakera ujian 24 GB menulis ~2.7 GB ke dalamnya (Build 14 lulus tetapi hanya tinggal ~1 GB).

#### Audit lapis kedua: `kimscan` + `kimlogpipe` (delegasi, belum dibetulkan)

4,355 baris dua alat itu **tidak** dibaca dalam audit pertama. Satu agent percuma
(`opencode/deepseek-v4.1-flash-free`) membaca penuh kedua-duanya dan melaporkan **7 penemuan**;
setiap satu saya sahkan semula dalam kod sebelum menerimanya:

| # | Lokasi | Kecacatan | Status |
|---|---|---|---|
| 1 | `kimlogpipe:1622` | `stderr=PIPE` tidak dibaca sehingga stdout tamat → journalctl tersekat, 0 event, pemantauan nampak "hidup" | disahkan; fix dirancang |
| 2 | `kimlogpipe:1830` | ralat follower → `exit 0`, jadi `Restart=on-failure` tidak restart | disahkan; fix dirancang |
| 3 | `kimscan:1310` | keutamaan `sshd_config` dibaca **terbalik** (drop-in ditambah di hujung) → `PasswordAuthentication yes` dalam drop-in dilaporkan bersih | disahkan; fix dirancang |
| 4 | `kimscan:1929` | `status <n>` mustahil untuk sesi posture (`posture_item()` tiada `fp`) | disahkan; fix dirancang |
| 5 | `kimscan:1018`, `kimlogpipe:884` | artifak 0755/0644: bukti mentah boleh dibaca user lain | disahkan; fix dirancang |
| 6 | `kimscan:1631` | label `PASS` walau ada finding HIGH | **keputusan Hayqal** — bukan pepijat jelas |
| 7 | `kimlogpipe:65` | pemalar hardcoded bercanggah dengan dakwaan `rules.yaml` "hardcodes no threshold value" | disahkan; fix dirancang |

Baseline sebelum disentuh: `kimlogpipe/test/run_tests.sh` **98/98**, `kimscanning/test/run_tests.sh`
**35/35**. Pelan pembetulan: `/tmp/opencode/build16-plan.md`. Ia **tidak** dimasukkan ke Build 15
supaya artifak yang diuji kekal sepadan dengan repo.

Hutang lain yang dicatat, bukan disorok: `install.sh:711` masih menulis `v3.11.1` sebagai literal
dalam mesej `--dry-run` walaupun `NUCLEI_VERSION` sudah diisytihar di baris 215 (mesej sahaja;
tidak mengubah apa yang dipasang) — Build 16.

### Build 16 — pembetulan penemuan audit lapis kedua (18 Nov)

Audit lapis kedua (agent percuma, laporan di `/tmp/opencode/report-kimscan.md`) menemui 7 perkara
dalam `kimscan` + `kimlogpipe`; semuanya saya sahkan semula dalam kod sebelum menyentuh apa-apa.
Enam dibetulkan, satu ditangguhkan kerana ia keputusan reka bentuk. Baseline sebelum perubahan:
`kimlogpipe` **98/98**, `kimscan` **35/35** — selepas perubahan, kedua-dua masih **98/98** dan **35/35**.

| # | Kecacatan | Pembetulan | Bukti regresi |
|---|---|---|---|
| 1 | `journalctl` menulis ke `stderr=PIPE` yang tiada pembaca → paip penuh (~64 KiB), `journalctl` tersekat, stdout berhenti, pemantau nampak "hidup" tetapi 0 event | thread kecil mengalirkan stderr ke 50 baris terakhir | `journalctl` palsu menulis **512 KiB** ke stderr → event masih masuk (`n=1`) |
| 2 | ralat follower menamatkan enjin dengan **exit 0**; `Restart=on-failure` tidak restart | `follower_failed` → `shutdown()` pulang 1 | `journalctl` palsu `exit 1` → `kimlogpipe follow` keluar **rc=1** |
| 3 | `Include` sshd dikembangkan di **hujung** fail, sedangkan sshd mengambil nilai **pertama** → drop-in `PasswordAuthentication yes` dilaporkan bersih (false negative) | `_sshd_lines()` mengembangkan `Include` **di tempatnya**, kekal dalam `SYSROOT` | fixture drop-in `yes` → `sshd:passwordauthentication` muncul dalam `posture` |
| 4 | `posture_item()` tiada `fp`; `status <n>` menukar nombor → `''` → sentiasa gagal | guna `fp`, jika tiada guna `key` | `kimscan status <sesi> 1 accepted` → exit 0 |
| 5 | artifak 0755/0644: baris log penuh + `gitleaks.json` (secret/match) boleh dibaca user lain | fail `0600`, direktori `0700` | `session.json=600`, dir `700`, `events.jsonl=600` |
| 6 | `PASS` di sebelah finding HIGH di bawah `--fail-on critical` | **tidak diubah** — keputusan reka bentuk verdict, bukan pepijat | — |
| 7 | `EVENT_ROTATE_BYTES` / `DEFAULT_COOLDOWN` hardcoded, bercanggah dengan dakwaan `rules.yaml` | boleh di-override melalui `KIMLOGPIPE_ROTATE_BYTES` / `KIMLOGPIPE_COOLDOWN` | `KIMLOGPIPE_ROTATE_BYTES=12345` → pemalar 12345 |

Ujian regresi keenam-enamnya disimpan dalam repo: `tests/build16-regressions.sh` (10 saat, tiada
kebergantungan luar selain bash + python3). Sebelum ini ia hanya wujud dalam `/tmp` — itu bukan bukti
yang boleh disemak semula, jadi ia dipindahkan ke repo.

#### ISO Build 16

| Perkara | Nilai |
|---|---|
| Fail | `kimrity-2026.11.18-x86_64.iso` (menggantikan Build 15; nama sama kerana tarikh sama) |
| Saiz | 1,327,243,264 bait (1.24 GiB) |
| sha256 | `f5b8320d17d3195c5883b10be395c3b49bc891bfcd9cf0989472029b9947671e` |
| `verify-iso.sh` | **19/19**, 0 gagal (`EXIT=0`, dibina ke `KIMRITY_OUT` berasingan supaya ISO Build 15 tidak ditimpa semasa proses) |
| Ujian install/boot | install `==> Done` (`INSTALL_EXIT=0`) → `verify-installed.sh` **66/66** (RAM 646 MiB, disk 2.7 GB) → reboot `boot_id` `e66b8a19…`→`2c0eb9a2…`, SSH balik ~10 s, **66/66** lagi, `--failed` 0/0 → boot **7.399 s** (userspace 1.959, `graphical.target` 1.826) |

Bukti pembetulan **di dalam sistem terpasang** (bukan hanya ujian hos):
`kimscan status <sesi> 1 accepted` → `rc=0` (dahulu sentiasa `fp '' not found`); `session.json` dan
`report.md` **0600**, direktori sesi **0700**; `kimscan posture` masih berjalan dan `kimscan`/`nuclei`/
`semgrep` hadir. Nota jujur: direktori induk `~/.local/share/kimscanning/sessions` kekal **0755** —
ia hanya mendedahkan id sesi, bukan kandungan; kandungan dilindungi oleh 0700/0600 di dalamnya.
