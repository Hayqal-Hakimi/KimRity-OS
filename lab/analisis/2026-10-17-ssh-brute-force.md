# Analisis Insiden — SSH Brute Force (simulasi terkawal)

| | |
|---|---|
| **Tarikh** | 2026-10-17, 09:44–09:45 waktu tempatan (+08) |
| **Mesin** | `arch-uji` (VM QEMU, kernel 7.2.9-arch1-1, sshd OpenSSH 10.6p1-2) |
| **Penganalisis** | Hayqal |
| **Sumber peristiwa** | Cubaan log masuk SSH dijana **dari hos** ke `127.0.0.1:2222` (hostfwd QEMU → port 22 guest) |
| **Status** | Simulasi terkawal — bukan serangan sebenar |
| **Rule** | [`../detections/ssh-brute-force.yml`](../detections/ssh-brute-force.yml) |
| **Bukti mentah** | [`../bukti/journal-sshd-2026-10-17.log`](../bukti/journal-sshd-2026-10-17.log) (38 baris, `journalctl -o short-iso`) |

## 1. Ringkasan

Sembilan cubaan log masuk SSH dihantar dari satu sumber dalam beberapa saat:
enam dengan nama pengguna tidak wujud, tiga dengan pengguna sah tetapi kunci salah.
sshd merekod empat kegagalan, kemudian **menghukum sumber itu sendiri**
(`srclimit_penalise` — penalti 19.644 saat) dan **menggugurkan 8 sambungan**.
Tiada pengesahan berjaya daripada sumber itu dalam tempoh ini.

Kesimpulan utama untuk detection engineering: **log tidak lengkap.**
Pertahanan sedia ada (OpenSSH `PerSourcePenalties`) memotong serangan sebelum semua
percubaan sampai ke peringkat pengesahan — jadi kiraan `Invalid user` sahaja
**terkurang kira**.

## 2. Persekitaran

| Perkara | Nilai |
|---|---|
| Perkhidmatan | `sshd` OpenSSH 10.6p1-2, port 22 guest |
| Pendedahan | Hanya `127.0.0.1:2222` di hos (hostfwd, loopback) — tidak terdedah ke LAN |
| Pengesahan | Kunci sahaja; `PermitRootLogin prohibit-password` |
| Log | `systemd-journald`, **kekal** (`/var/log/journal`, 32 MB digunakan) |
| Sumber yang dilihat guest | `10.0.2.2` (gateway slirp QEMU), bukan `127.0.0.1` |
| Polisi berkaitan | `MaxAuthTries 6` · `PerSourcePenalties authfail:5s invaliduser:5s grace-exceeded:10s min:15s max:600s` · `PerSourcePenaltyExemptList none` |

## 3. Timeline (semua +08)

| Masa | Peristiwa |
|---|---|
| 09:42:30 | `Connection closed by authenticating user root 10.0.2.2 port 51640 [preauth]` — cubaan root **sebelum** kunci dipasang |
| 09:44:00 | `Accepted publickey for hayqal …` — sesi SSH sah (bukan penyerang) |
| 09:44:51 | `Invalid user admin … port 49986` → `Connection closed by invalid user … [preauth]` |
| 09:44:51 | `Invalid user root_test … port 49994` → ditutup |
| 09:44:51 | `Invalid user oracle … port 49998` → ditutup |
| 09:44:52 | `Invalid user ftpuser … port 50000` → ditutup |
| 09:44:52 | `srclimit_penalise: 10.0.2.2/32: activating ipv4 penalty of 19.644 seconds … attempted authentication by invalid user` |
| 09:44:52 | **6** baris `drop connection … from [10.0.2.2] … on [10.0.2.15]:22 … penalty` (port 50014–50066) |
| 09:45:02 | **2** baris `drop connection … penalty` lagi (port 42410, 42418) |
| 09:46:23+ | `Accepted publickey for root …` — sesi sah kita selepas penalti luput |

## 4. Bukti (verbatim, 38 baris penuh dalam fail bukti)

```
2026-10-17T09:44:51+08:00 arch-uji sshd-session[581]: Invalid user admin from 10.0.2.2 port 49986
2026-10-17T09:44:51+08:00 arch-uji sshd-session[581]: Connection closed by invalid user admin 10.0.2.2 port 49986 [preauth]
2026-10-17T09:44:51+08:00 arch-uji sshd-session[583]: Invalid user root_test from 10.0.2.2 port 49994
2026-10-17T09:44:51+08:00 arch-uji sshd-session[585]: Invalid user oracle from 10.0.2.2 port 49998
2026-10-17T09:44:52+08:00 arch-uji sshd-session[587]: Invalid user ftpuser from 10.0.2.2 port 50000
2026-10-17T09:44:52+08:00 arch-uji sshd[328]: srclimit_penalise: 10.0.2.2/32: activating ipv4 penalty of 19.644 seconds for penalty: attempted authentication by invalid user
2026-10-17T09:44:52+08:00 arch-uji sshd[328]: drop connection #0 from [10.0.2.2]:50014 on [10.0.2.15]:22 penalty: attempted authentication by invalid user
```

Kiraan daripada fail bukti:

| Corak | Bilangan |
|---|---|
| `Invalid user` | **4** (admin, root_test, oracle, ftpuser) |
| `drop connection … penalty` | **8** (6 pada 09:44:52 + 2 pada 09:45:02) |
| `srclimit_penalise` | 1 (19.644 s) |
| `Accepted` daripada sumber itu | 5 — **semua** `publickey` untuk `hayqal`/`root` (sesi kita sendiri, bukan penyerang) |

## 5. Analisis

1. **Corak:** banyak nama pengguna berbeza dari satu sumber dalam ~2 saat →
   brute-force / user enumeration (MITRE **T1110.001**), bukan serangan bertarget.
2. **Sasaran nama akaun:** `admin`, `root_test`, `oracle`, `ftpuser` — akaun lalai
   perkhidmatan; corak pengimbas automatik, bukan manusia.
3. **Pertahanan bertindak sendiri:** OpenSSH 10 bawa `PerSourcePenalties` (aktif
   secara lalai). Penalti 19.644 s > asas 5 s → ia **bertambah** mengikut kekerapan.
4. **Tiga cubaan "pengguna sah + kunci salah" tidak muncul sebagai kegagalan auth** —
   ia muncul sebagai `drop connection … penalty`. Ini bukti langsung bahawa penalti
   memotong percubaan **sebelum** peringkat pengesahan.
5. **Aritmetik tidak sepadan dengan tepat:** 9 cubaan dihantar, tetapi 4 diproses +
   8 digugurkan = 12 baris. Kemungkinan klien `ssh` mencuba semula sambungan
   (satu cubaan → lebih daripada satu sambungan). **Belum disahkan** — langkah
   seterusnya ialah kira sambungan TCP, bukan hanya baris log.
6. **Tiada kejayaan daripada sumber itu:** semua `Accepted` ialah kunci kita sendiri
   (SHA256 `V+LYAN…`). Tiada `Accepted password`, tiada sesi baharu yang tidak dikenali.

## 6. Rule dan padanan dalam amalan

Rule: [`ssh-brute-force.yml`](../detections/ssh-brute-force.yml) — Sigma,
`selection | count() by src_ip > 5` dalam tetingkap 5 minit.

Tiada enjin Sigma dalam makmal ini, jadi logiknya disahkan dengan query setara
pada log sebenar:

```bash
journalctl -u sshd --since '-15 min' --no-pager -o cat \
  | grep -E 'Invalid user|Failed password|Failed publickey|Connection closed by authenticating|drop connection' \
  | grep -oE 'from (\[)?[0-9.]+' | sort | uniq -c | sort -rn
```

**Batasan:** `src_ip` ialah medan *ternormal* (Wazuh/Elastic/Vector). Journald
mentah tiada medan itu — ia perlu diekstrak dahulu. **Jurang ini mesti ditutup oleh
pipeline log OS** sebelum rule boleh dijalankan oleh enjin sebenar.

## 7. Positif palsu / batasan eksperimen

- Pengimbas sah, skrip backup dengan kelayakan basi, pengguna tersalah taip berulang.
- Satu sumber sahaja (`10.0.2.2`) — tidak menguji serangan merentas banyak IP
  (yang akan mengelak `count() by src_ip`).
- Cubaan dihantar dari hos, jadi "penyerang" sentiasa kelihatan sebagai gateway slirp.
  Ujian berbilang sumber memerlukan bridge/`socket_vmnet` atau VM kedua.
- Ambang `>5` dipilih daripada amalan biasa, **bukan** daripada data 30 hari mesin ini.

## 8. Tindakan yang akan diambil (peranan analis SOC)

1. **Sahkan** sumber: dalam makmal ini `10.0.2.2` = hos, jadi aktiviti dijangka.
2. **Kira semula** dengan baris `drop connection` + `srclimit_penalise` supaya jumlah
   percubaan tidak terkurang.
3. **Semak `Accepted`** daripada sumber yang sama selepas penalti luput — jika ada
   sesi yang tidak dikenali, naik taraf kepada insiden pengkompromian.
4. **Sekat** sumber pada peringkat rangkaian (pengeluaran: firewall/ACL) dan
   **putar** kelayakan jika ada tanda kejayaan.
5. **Tala ambang:** `MaxAuthTries 6` bermakna >5/5min mungkin terlalu rendah untuk
   pengguna sebenar; cadangan 10/5min untuk persekitaran kecil, disahkan dengan data.

## 9. Pelajaran untuk OS (input kepada reka bentuk)

| Penemuan | Kesan pada OS |
|---|---|
| journald **tidak kekal** secara lalai | Skrip install mesti `mkdir -p /var/log/journal` + had saiz |
| `hostname`/`ping` tiada dalam pemasangan minimal | Tambah `inetutils`/`iputils` atau guna `hostnamectl` |
| `PerSourcePenalties` aktif secara lalai | Detector mesti kira `drop connection`, bukan hanya `Invalid user` |
| Sumber dari hos sentiasa `10.0.2.2` | Ujian berbilang sumber perlu bridge/VM kedua, bukan NAT user-mode |
| Penalti menyekat SSH kita sendiri | Dalam lab, tetapkan `PerSourcePenaltyExemptList` **hanya** semasa ujian, dan rekod keputusan itu |
