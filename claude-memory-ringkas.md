# Memory ringkas projek OS — untuk Claude (sambungan)

Ditulis 17 Okt 2026. Hanya keadaan projek OS. Salin blok di bawah.

---

```
Memory projek OS Security + AI — keadaan 17 Okt 2026.

TUJUAN (seperti yang kita bincang dulu): OS Linux keselamatan (Arch + Hyprland) untuk
Hayqal guna sendiri — desktop harian + makmal belajar. Bukti projek = artifak security
(rule deteksi + laporan + log bukti). OS cuma kenderaan.

HOS
Omarchy (Arch+Hyprland), i5-4590, 7.2 GiB RAM. sda = Windows (sda3) + ISO Omarchy (sda4)
— jangan disentuh. Root guna pkexec, bukan sudo.

VM (semua kerja di sini): /home/hayqal/vm/ujian/
- disk.qcow2 40 GiB = sistem kerja · uji2.qcow2 24 GiB = hasil ujian installer
- UEFI OVMF 4m, QEMU 11.1.1 KVM, hostfwd 127.0.0.1:2222→22
- Alat: ~/vm/ujian/alat/ (qmp.sh, qsend.py, send_cmd.sh, vm_mula.sh, pelayan.sh)
- VM jalan sebagai unit systemd pengguna `vm-arch-uji` (tak mati bila terminal tutup)

  hidupkan : bash ~/vm/ujian/alat/vm_mula.sh
  masuk    : ssh -p 2222 -i ~/.ssh/vm_arch_uji hayqal@127.0.0.1   (root@ sama kunci)
  skrin    : bash ~/vm/ujian/alat/qmp.sh '{"execute":"screendump","arguments":{"filename":"/home/hayqal/vm/ujian/s.png","format":"png"}}'
  kekunci  : bash ~/vm/ujian/alat/qsend.py 'teks'   (Enter = --key c-m)
  fail ke guest: python3 -m http.server 8000 --bind 0.0.0.0 --directory ~/vm/ujian/arahan
                 → guest: curl -so /tmp/f 10.0.2.2:8000/<fail>  (127.0.0.1 tak jalan)

GUEST (disahkan hari ini)
- Arch kernel 7.2.9-arch1-1, hostname arch-uji, user hayqal (UID 1000, wheel) + root.
- vda1 ESP vfat · vda2 btrfs subvol @ (/) + @home, compress=zstd:3
- Boot: Limine 12.9.3, /boot/EFI/BOOT/BOOTX64.EFI + limine.conf (fallback) + entri NVRAM.
  cmdline root=UUID=2fd45521-7593-4ba2-b2a5-735d0dea7e02 rw rootflags=subvol=@
  (`rootflags=subvol=@` wajib)
- SSH kunci (hayqal + root), journald kekal /var/log/journal (32M)
- sshd 10.6 dengan PerSourcePenalties — cubaan gagal berulang menyekat sambungan sekejap
- Desktop: Hyprland 0.56.2, waybar 0.15.0, kitty 0.49.2, mako, wofi, xdg-desktop-portal(-hyprland),
  pipewire + wireplumber, polkit. Tiada display manager — autostart dari ~/.bash_profile.
- Tool: git 2.56.0, base-devel, btop 1.4.7, wl-clipboard, grim, slurp, tcpdump 4.99.7,
  nmap 7.99, audit 4.2.1 (auditd enabled), yara 4.5.8, firefox 158.0, gptfdisk, iputils, inetutils
- Servis enabled: NetworkManager, sshd, auditd
- Belum ada: archiso/ISO, BlackArch, SIEM, kod broker/agent

FAIL
~/Documents/projects/os-security-ai/
  install.sh        pemasang satu fail, 9 langkah, ada guard + --dry-run
  dotfiles/         hypr/hyprland.conf, kitty/kitty.conf, waybar/{config.jsonc,style.css}, bash_profile
  lab/detections/ssh-brute-force.yml   (Sigma, id 9e18bab4-fa4b-4f42-8f8a-b2a2d9d90841)
  lab/analisis/2026-10-17-ssh-brute-force.md
  lab/bukti/journal-sshd-2026-10-17.log   (38 baris)
Nota: ~/Documents/brainQ/projects/os-security-ai.md

ARTIFAK #1 — SIAP
SSH brute-force: 9 cubaan gagal dari hos → 4 `Invalid user` + 8 `drop connection` +
penalti sshd 19.644 s → rule (count by src_ip > 5 dalam 5 min) + laporan + bukti.
Penemuan: journald tak kekal secara lalai · minimal tiada hostname/ping · penalti sshd
memotong log (kena kira `drop connection`) · sumber dari hos sentiasa 10.0.2.2

INSTALLER — SIAP & DIUJI
--disk wajib (tiada nilai lalai). Guard: bukan root / bukan block device / partisi bukan disk /
disk dilekap / disk memegang ISO / NTFS tanpa --force / <20 GiB / bukan UEFI.
Pilihan: --hostname --user --timezone --dotfiles --dry-run --yes --force --efi
Ujian: disk 24 GiB → EXIT=0, 524 pakej, kemudian boot sendiri dalam VM kedua (headless,
NVRAM segar) → Arch Linux 7.2.10 (tty1) arch-uji login:
Dua pepijat dibetulkan: partprobe tiada (ganti udevadm settle + tunggu node partisi) dan
nama pakej auditd (betul: `audit`).

TINGGAL
1. Artifak #2 (keutamaan): contoh deteksi perubahan /etc/passwd·sudoers·authorized_keys
   dengan auditd, atau "fail then success" selepas brute-force.
2. BlackArch dalam guest (bukan hos).
3. ISO archiso — paling akhir.
4. Kemas desktop (wallpaper, screenshot, clipboard).

CATATAN: password tak pernah melalui AI — dia taip sendiri. Satu password root pernah
terlepas dalam log chat, jadi mesti ditukar. Kau tiada akses mesin; minta dia paste output.
```
