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
