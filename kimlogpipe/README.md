# KimLogPipe v1

KimLogPipe menukar log sistem daripada **journald** dan **auditd** kepada satu
skema peristiwa seragam (JSONL), menjalankan empat peraturan ambang, dan
menghasilkan laporan dalam Bahasa Melayu.

- Tiada AI, tiada model, tiada rangkaian.
- Satu fail boleh laku: `kimlogpipe/kimlogpipe` (Python 3, perpustakaan standard).
- Semua tulisan pergi ke `$XDG_DATA_HOME/kimlogpipe/` (fallback
  `~/.local/share/kimlogpipe/`). Tiada tulisan ke `/etc`, systemd, atau
  `~/.config`.

## Skop v1

Fail yang dihasilkan/diubah dalam tugasan ini hanya di bawah `kimlogpipe/**`:

```
kimlogpipe/kimlogpipe        # CLI (executable)
kimlogpipe/rules.yaml        # definisi peraturan + ambang (data)
kimlogpipe/README.md         # dokumen ini
kimlogpipe/test/run_tests.sh # ujian dengan HOME/XDG sementara
kimlogpipe/fixtures/         # fixture sebenar (tidak diubah)
```

Storan runtime (dibenarkan):

```
$XDG_DATA_HOME/kimlogpipe/events.jsonl    # peristiwa seragam
$XDG_DATA_HOME/kimlogpipe/findings.json   # hasil detect terkini
$XDG_DATA_HOME/kimlogpipe/rawlines.jsonl  # sidecar baris mentah untuk bukti
```

`rawlines.jsonl` ialah fail dalaman supaya `evidence[].line` boleh memetik
baris log asal walaupun fail sumber kemudiannya dipindahkan. Ia bukan skema
peristiwa dan tidak mengubah `events.jsonl`.

## Keperluan

- Python 3.8 atau lebih baru.
- PyYAML **pilihan**. Jika tiada, KimLogPipe menggunakan parser YAML mini
  terbina dalam untuk subset yang digunakan oleh `rules.yaml`.
- Untuk mod langsung: `journalctl` (systemd) dan/atau akses baca
  `/var/log/audit/audit.log`.

## Penggunaan

```bash
# Serap fixture journald
./kimlogpipe/kimlogpipe ingest --source journald --file kimlogpipe/fixtures/f_sshd.jsonl

# Serap fixture auditd
./kimlogpipe/kimlogpipe ingest --source auditd --file kimlogpipe/fixtures/f_audit.log

# Mod langsung
./kimlogpipe/kimlogpipe ingest --source journald
./kimlogpipe/kimlogpipe ingest --source auditd

# Senarai peraturan + ambang
./kimlogpipe/kimlogpipe rules

# Jalankan semua peraturan (semua peristiwa, atau tetingkap masa)
./kimlogpipe/kimlogpipe detect
./kimlogpipe/kimlogpipe detect --since 5m

# Laporan manusia Bahasa Melayu
./kimlogpipe/kimlogpipe report
```

Mod langsung journald menjalankan:

```bash
journalctl -o json --no-pager -n 2000
```

Bilangan baris boleh diubah dengan `KIMLOGPIPE_JOURNAL_LINES`. Mod langsung
auditd membaca `/var/log/audit/audit.log`; laluan boleh diubah dengan
`KIMLOGPIPE_AUDIT_LOG` (berguna untuk ujian baca-sahaja).

`raw_ref` ialah:

- `laluan_mutlak:baris` semasa `--file` (journald/auditd) dan auditd langsung;
- `__CURSOR` journald semasa journald langsung.

## Skema peristiwa seragam

Satu objek JSON per baris dalam `events.jsonl`:

```json
{"ts":"ISO8601","source":"journald|auditd","host":"","user":"","src_ip":"","action":"","outcome":"success|failed|unknown","raw_ref":"file:line atau cursor"}
```

| Medan | Maksud |
|---|---|
| `ts` | Masa daripada log itu sendiri, dalam UTC ISO8601 (mikrosaat, akhiran `Z`). |
| `source` | `journald` atau `auditd`. |
| `host` | `_HOSTNAME` journald; `node=` auditd jika ada, jika tidak `""`. |
| `user` | Pengguna yang diekstrak daripada mesej/medan log; `""` jika tiada. |
| `src_ip` | IP sumber jika log menyatakannya; **sentiasa `""` jika tiada**. Tiada IP direka. |
| `action` | Tindakan ternormal (lihat jadual di bawah). |
| `outcome` | `success`, `failed`, atau `unknown`. |
| `raw_ref` | Rujukan baris asal atau cursor journald. |

### Tindakan ternormal

| Action | Sumber | Maksud |
|---|---|---|
| `ssh_login` | journald | `Accepted ...` |
| `ssh_auth_failed` | journald | `Failed password`, `Failed publickey`, kegagalan PAM sshd |
| `ssh_invalid_user` | journald | `Invalid user ...` |
| `ssh_drop` | journald | `drop connection`, atau `Connection closed by ... [preauth]` |
| `ssh_session_open` / `ssh_session_close` | journald | Sesi PAM sshd dibuka/ditutup |
| `ssh_service` | journald | sshd mula mendengar/bermula |
| `sudo_fail` / `su_fail` | journald, auditd | Kegagalan pengesahan sudo/su |
| `sudo` / `su` | journald, auditd | Rekod sudo/su bukan kegagalan |
| `aide_change` | journald | Baris laporan AIDE (added/removed/changed/differences) |
| `auth_failed` | journald | Kegagalan pengesahan am (bukan sshd/sudo/su) |
| `user_auth` | auditd | `type=USER_AUTH` bukan sudo/su |
| `user_start`, `cred_acq`, `service_start`, ... | auditd | Jenis rekod audit diturunkan ke huruf kecil |
| `syscall:<nama>` | auditd | Panggilan sistem bukan execve, contoh `syscall:close` |
| `execve:<basename>` | auditd | `execve`/`execveat`; contoh `execve:nmap` |
| `log` | journald | Rekod am tanpa pengelasan khas |

## Medan sebenar yang digunakan (disemak pada fixture)

### `fixtures/f_sshd.jsonl` — 40 baris `journalctl -o json -u sshd`

Medan yang benar-benar dilihat dan digunakan:

| Medan | Contoh / lokasi | Kegunaan |
|---|---|---|
| `__REALTIME_TIMESTAMP` | `"1793008919317763"` (baris 1) | mikrosaat epoch → `ts` |
| `_SOURCE_REALTIME_TIMESTAMP` | baris 1 | sandaran `ts` jika medan utama tiada |
| `_HOSTNAME` | `"arch-uji"` | `host` |
| `MESSAGE` | `"Accepted publickey for root from 10.0.2.2 ..."` | `action`, `outcome`, `user`, `src_ip` |
| `SYSLOG_IDENTIFIER` | `"sshd-session"`, `"sshd"`, `"systemd"` | pengelasan sshd/sudo/su/aide |
| `_COMM` | `"sshd-session"`, `"systemd"` | pengelasan tambahan |
| `__CURSOR` | `"s=f87a83...;i=7b6e;..."` | `raw_ref` dalam mod langsung |

Medan yang wujud tetapi **tidak** digunakan: `_PID`, `SYSLOG_PID`, `_UID`,
`_GID`, `SYSLOG_TIMESTAMP`, `_EXE`, `_CMDLINE`, `_SYSTEMD_UNIT`,
`_SYSTEMD_CGROUP`, `__MONOTONIC_TIMESTAMP`, `PRIORITY`. `SYSLOG_TIMESTAMP`
tidak digunakan kerana ia waktu tempatan tanpa tahun dan kurang tepat
berbanding epoch; `ts` diambil daripada `__REALTIME_TIMESTAMP`.

Nota: fixture ini hanya mengandungi log masuk **berjaya** (`Accepted`,
`session opened/closed`, `Server listening`, `Starting/Started OpenSSH`).
Tiada `Failed password`, `Invalid user`, atau `drop connection`.

### `fixtures/f_audit.log` — 30 baris `/var/log/audit/audit.log`

Medan yang dilihat dan digunakan:

| Medan | Contoh / lokasi | Kegunaan |
|---|---|---|
| `type=` | `SYSCALL`, `PROCTITLE`, `BPF`, `SERVICE_START`, `USER_START`, `CRED_ACQ` | pengelasan rekod; jenis utama peristiwa |
| `msg=audit(EPOCH.mmm:ID)` | `msg=audit(1793192826.455:98)` | `ts` (saat+milisaat) dan pengumpulan mengikut `ID` |
| `syscall`, `SYSCALL` | `syscall=321`, `SYSCALL=bpf` | nama panggilan sistem; `execve` dikesan |
| `success` | `success=yes` | `outcome` |
| `exe` | `exe="/usr/lib/systemd/systemd"` | basename untuk `execve:<basename>` |
| `comm` | `comm="systemd"` | konteks proses |
| `auid`, `uid`, `AUID`, `UID` | `auid=0 ... AUID="root" UID="root"` | `user` |
| `pid`, `ppid`, `ses`, `tty` | baris 1 | konteks (tidak masuk skema) |
| `msg='...'` (dalam USER_START/CRED_ACQ/SERVICE_START) | `acct="root" ... addr=10.0.2.2 ... res=success` | `user`, `src_ip`, `outcome` |
| `acct` | `acct="root"` | `user` diutamakan |
| `addr` | `addr=10.0.2.2` | `src_ip` sahaja (nilai `?` diabaikan) |
| `hostname` | `hostname=10.0.2.2` | sandaran `src_ip` jika `addr` tiada |
| `res` | `res=success` / `res=failed` | `outcome` |
| `node=` | tiada dalam fixture | `host` jika ada; jika tiada, `host=""` |
| `a0`, `a1`, ... (EXECVE) | tiada dalam fixture | argv; `a0` sandaran untuk binari |
| `argc` (EXECVE) | tiada dalam fixture | bilangan argumen (tidak masuk skema) |

Rekod audit dengan `ID` yang sama dikumpulkan menjadi **satu** peristiwa
(contohnya `SYSCALL` + `PROCTITLE` + `EXECVE`). 30 baris fixture menjadi
**13** peristiwa.

Fixture ini **tidak** mengandungi `type=USER_AUTH` atau `type=EXECVE`.
Parser menyokong kedua-duanya dan ia diuji dengan baris sintetik dalam
`test/run_tests.sh`. `host` auditd kekal `""` kerana fixture tiada `node=`.

## Peraturan v1 (`rules.yaml`)

Semua ambang ialah data dalam `rules.yaml`; enjin tidak menyimpan nombor
ambang secara hardcode.

| Peraturan | Severity | Ambang / syarat | Kunci |
|---|---|---|---|
| `ssh_bruteforce` | high | ≥ **5** isyarat gagal dalam **300 saat** | `src_ip` |
| `sudo_fail` | high | sebarang `sudo_fail`/`su_fail` | `user` |
| `audit_exec_watch` | medium | `execve` bagi `nmap`, `nc`, `curl`, `wget` | `user` |
| `aide_change` | medium | sebarang baris AIDE added/removed/changed | `user` |

Isyarat `ssh_bruteforce`:

- `ssh_auth_failed` (`Failed password`, `Failed publickey`, kegagalan PAM)
- `ssh_invalid_user` (`Invalid user`)
- `ssh_drop` (`drop connection`, `Connection closed by ... [preauth]`)

Tetingkap 5 minit ialah tetingkap gelongsor. Jika 5 isyarat berlaku dalam
mana-mana 300 saat, peraturan menyala; `count` ialah bilangan isyarat dalam
tetingkap terbaik, dan `first_ts`/`last_ts` ialah sempadan tetingkap itu.

Setiap dapatan:

```json
{"rule":"...","severity":"...","count":5,"first_ts":"...","last_ts":"...",
 "key":"10.0.2.2","evidence":[{"raw_ref":"file:line","line":"baris mentah"}],
 "summary_bm":"..."}
```

## Tiga status `detect` (kejujuran)

`detect` mencetak satu baris bagi setiap peraturan:

1. **Dapatan** — contoh `ssh_bruteforce: 1 dapatan`.
2. **`tiada padanan`** — data yang berkaitan wujud, tetapi tiada ambang
   dicapai. Contoh pada fixture sebenar: `ssh_bruteforce` ada peristiwa
   pengesahan SSH (dan medan `src_ip` wujud) tetapi **sifar** isyarat
   kegagalan, jadi hasilnya `tiada padanan`.
3. **`tidak dapat dinilai (…)`** — data yang diperlukan langsung tiada.
   Contoh pada fixture sebenar:
   - `sudo_fail`: tiada rekod sudo/su;
   - `audit_exec_watch`: tiada rekod `execve` (tiada `EXECVE`/`execve` dalam fixture audit);
   - `aide_change`: tiada baris AIDE.

Status 2 dan 3 **bukan** bukti ketiadaan serangan. Tiada dapatan direka.
Laporan `report` memaparkan sebab bagi setiap status.

## Dedupe

`ingest` menyimpan kunci `(ts, source, action, raw_ref)`. Menjalankan
`ingest` semula pada fixture yang sama menambah **0** peristiwa baharu dan
melaporkan bilangan pendua yang dilangkau. `events.jsonl` tidak bertambah.

## Kaveat operasi (penting)

### 1. journald tidak kekal secara lalai

Journal systemd biasanya menggunakan `Storage=volatile` (atau auto) secara
lalai. Log hilang selepas reboot dan `journalctl` hanya melihat boot semasa.
Jika log lama diperlukan, pentadbir perlu menetapkan `Storage=persistent`
dalam `journald.conf` (di luar skop alat ini). KimLogPipe tidak mengubah
konfigurasi journald.

### 2. `PerSourcePenalties` memotong log sshd

OpenSSH moden boleh menghukum sumber yang gagal berulang kali dan menutup
sambungan lebih awal. Apabila ini berlaku, sshd mungkin **tidak** menulis
`Invalid user` atau `Failed password`; yang kelihatan hanyalah baris seperti:

```
drop connection #0 from 10.0.2.2 port 40006
```

Oleh itu `ssh_bruteforce` mengira **kedua-dua** isyarat: kegagalan pengesahan
biasa **dan** `drop connection` / `Connection closed ... [preauth]`. Ini
heuristik yang didokumenkan, bukan bukti muktamad. Dalam environment dengan
penalti aktif, bilangan sebenar percubaan mungkin lebih tinggi daripada
bilangan baris log.

### 3. VM NAT QEMU: semua sumber luar = `10.0.2.2`

Dalam VM yang menggunakan NAT QEMU (contohnya `user` networking), hos luar
kelihatan sebagai `10.0.2.2`. Semua percubaan daripada mesin luar akan
berkongsi kunci `src_ip` yang sama. Ini normalisasi yang betul pada peringkat
log, tetapi ia **tidak** membezakan hos sebenar di luar NAT. Jangan tafsir
`10.0.2.2` sebagai penyerang tunggal tanpa konteks rangkaian. Kaveat ini juga
dicetak dalam `report`.

### 4. auditd: `saddr` tidak dihurai

Rekod audit kadangkala membawa alamat sumber dalam bentuk hex (`saddr=...`).
KimLogPipe tidak menukar hex kepada IP kerana itu berisiko mencipta nilai
yang salah. `src_ip` hanya diambil daripada `addr=`/`hostname=` yang berupa
teks. Jika tiada, `src_ip=""`.

### 5. AIDE

AIDE tidak menulis ke journal secara lalai. v1 tiada `--source aide`
berasingan; baris AIDE dikesan jika ia sampai ke journald (contohnya melalui
systemd timer/logger) atau dimasukkan dalam fail input berformat journald.
Fixture sebenar tiada baris AIDE, jadi peraturan ini tidak dapat dinilai
pada fixture tersebut (tetapi diuji dengan input sintetik).

### 6. Zon waktu

`ts` sentiasa UTC daripada epoch log. `SYSLOG_TIMESTAMP` journald (waktu
tempatan, contoh `Oct 26 18:01:59`) tidak digunakan. Ini mengelakkan
kekeliruan zon waktu dan tahun yang tiada dalam format syslog.

## Had v1 / yang tidak diuji

- **Mod langsung tidak diuji** dalam environment ini: tiada jaminan journal
  kekal/ boleh dibaca untuk semua unit, dan pembacaan `/var/log/audit/audit.log`
  memerlukan keistimewaan. Kod laluan langsung dilaksanakan tetapi bukan
  sebahagian daripada bukti penerimaan.
- **`USER_AUTH` dan `EXECVE` auditd tidak ada dalam fixture sebenar**; ia
  diuji dengan baris sintetik yang meniru format audit sebenar.
- **`sudo_fail` / `aide_change` tidak ada dalam fixture sebenar**; diuji
  dengan input sintetik.
- Kumpulan audit diandaikan mengikut `msg=audit(...:ID)` dan fail disusun
  mengikut masa. Fail yang bermula di tengah-tengah peristiwa masih dihurai
  sebagai kumpulan separa.
- `execve` dikesan melalui `SYSCALL=execve` (nama yang diselesaikan auditd)
  atau nombor syscall x86_64 `59`/`322`. Arkitektur lain yang tidak menulis
  `SYSCALL=` mungkin memerlukan pemetaan nombor tambahan.
- Tiada pengesahan tandatangan, tiada penyulitan storan, tiada pengurusan
  log rotate. Storan adalah fail teks biasa di bawah direktori data pengguna.
- Tiada pemasangan pakej, tiada perubahan systemd/`/etc`, tiada rangkaian.

## Ujian

```bash
HOME=<tempdir> XDG_DATA_HOME=<tempdir>/.local/share \
  bash kimlogpipe/test/run_tests.sh
```

Ujian menggunakan `HOME` dan `XDG_DATA_HOME` sementara, menyemak:

- `py_compile`;
- `rules` (termasuk parser YAML fallback);
- skema `events.jsonl` (kunci tepat, `ts` ISO8601 UTC, `outcome` sah);
- dedupe ingest semula;
- `detect` pada fixture sebenar (termasuk status "tidak dapat dinilai");
- `report` Bahasa Melayu;
- `ssh_bruteforce` (ambang, tetingkap gelongsor, isyarat `drop connection`,
  IP bawah ambang dan IP tersebar tidak dilaporkan);
- `sudo_fail` (journald dan auditd `USER_AUTH`);
- `audit_exec_watch` (`nmap` dilaporkan, `ls` tidak);
- `aide_change`;
- `--since`;
- pengasingan storan (tiada tulisan ke `$HOME/.local/share` sebenar).

## Privasi dan keselamatan

- Tiada rangkaian, tiada telemetri, tiada AI/model.
- Input dibaca sahaja. Satu-satunya subprocess ialah `journalctl` untuk mod
  langsung journald, dipanggil dengan senarai argumen (tiada shell).
- Output hanya di bawah `$XDG_DATA_HOME/kimlogpipe/`.
- `evidence[].line` memetik baris log asal dan boleh mengandungi nama
  pengguna/IP; lindungi direktori storan seperti log sistem biasa.

## Lesen / status

Prototaip v1 untuk tugasan `kimlogpipe`. Bukan alat pengeluaran.
