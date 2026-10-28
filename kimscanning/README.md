# KimScanning v1

KimScanning ialah alat baris perintah gaya `nmap` yang membalut
[`gate/gate.py`](../gate/gate.py). Setiap imbasan disimpan sebagai **objek
sesi**, setiap dapatan dijelaskan dalam **Bahasa Melayu menggunakan kamus
statik** (`rules/bm.yaml`), dan status dapatan dikekalkan merentas imbasan
berulang. Tiada AI, tiada panggilan rangkaian daripada KimScanning sendiri.

KimScanning tidak membuat verdict sendiri: verdict datang daripada
KimRity Security Gate. Jika alat pengimbas tiada atau gagal, gate tidak
memberi kelulusan dan KimScanning merekodkannya secara jujur.

## Keperluan

- Python 3 (hanya pustaka standard; PyYAML digunakan jika ada, jika tidak
  parser kecil terbina digunakan).
- `gate/gate.py` dalam repositori yang sama.
- Alat pengimbas pada `PATH`:
  - `repo`: `gitleaks`, `semgrep`, `trivy`
  - `web`: `nuclei`, `nikto`
  - `server`: `nmap`, `ssh-audit` (ssh-audit hanya jika port 22 dibuka)
- `kimscan doctor` menyemak setiap alat dengan `command -v` ( melalui
  `shutil.which`) dan melaporkan yang tiada sebagai **tiada**. Ia tidak
  pernah menganggap alat yang tidak dipasang sebagai tersedia.

## Penggunaan

```text
kimscan repo <folder> [--scope S] [--json] [--fail-on critical|high|medium]
kimscan web <url> --authorized [--scope S] [--json] [--fail-on T]
kimscan server <host> --authorized [--scope S] [--json] [--fail-on T]
kimscan list
kimscan show <id> [--json]
kimscan status <id> <fp> baru|diterima|dibetulkan
kimscan rules [--missing]
kimscan doctor
kimscan help
```

Contoh:

```bash
./kimscanning/kimscan doctor
./kimscanning/kimscan repo .
./kimscanning/kimscan repo ~/projek --fail-on medium
./kimscanning/kimscan web https://127.0.0.1 --authorized --scope skop.txt
./kimscanning/kimscan show 20261028T120000Z
./kimscanning/kimscan status 20261028T120000Z a1b2c3d4e5f6 diterima
./kimscanning/kimscan rules --missing
```

`web` dan `server` ialah imbasan aktif. Kedua-duanya **enggan berjalan**
tanpa `--authorized` dan keluar dengan kod 1. Pengguna bertanggungjawab
memastikan kebenaran bertulis sebelum menggunakan flag itu.

### NDJSON untuk GUI

Dengan `--json`, stdout hanya mengandungi satu objek JSON setiap baris:

```json
{"phase":"start","id":"20261028T120000Z","kind":"repo","target":"/x","started":"..."}
{"phase":"scanner","name":"gitleaks","status":"done","rc":0,"reason":"selesai"}
{"phase":"scanner","name":"semgrep","status":"done","rc":0,"reason":"selesai"}
{"phase":"scanner","name":"trivy","status":"done","rc":0,"reason":"selesai"}
{"phase":"done","id":"20261028T120000Z","verdict":"LULUS","counts":{...},"exit":0}
```

Ralat pengawal dan ralat penggunaan ditulis ke stderr.

## Kod keluar

| Kod | Maksud |
|---:|---|
| 0 | LULUS |
| 1 | ralat penggunaan / pengawal kebenaran |
| 2 | BERSYARAT |
| 3 | TIDAK LULUS |

Verdict gate `LULUS BERSYARAT` dipetakan kepada `BERSYARAT` dalam
`session.json` supaya tepat mengikut skema sesi.

## Sesi

Lokasi:

```text
$XDG_DATA_HOME/kimscanning/sessions/<YYYYMMDDTHHMMSSZ>/
```

Jika `XDG_DATA_HOME` tidak ditetapkan:

```text
~/.local/share/kimscanning/sessions/<YYYYMMDDTHHMMSSZ>/
```

Setiap sesi mengandungi:

- `session.json` — objek sesi (schema di bawah)
- `raw/` — keluaran mentah setiap pengimbas, `gate.json`, dan laporan gate
- `report.md` — laporan manusia dalam Bahasa Melayu

Skema `session.json`:

```text
id, kind, target (absolut untuk repo), profile,
authorized{granted,who,when,scope},
started, finished, verdict (LULUS|BERSYARAT|TIDAK LULUS),
scanners[{name,status(done|failed|skipped),rc,reason}],
counts{critical,high,medium,low},
findings[{fp,tool,rule,severity,file,line,message,evidence,
          explanation{apa,bahaya,buat} | null,
          status(baru|diterima|dibetulkan),first_seen,last_seen}]
```

### Cap jari dan status

```text
fp = sha1(tool + "|" + rule + "|" + file + "|" + line)[:12]
```

Apabila imbasan baharu bagi `kind+target` yang sama menghasilkan `fp` yang
pernah dilihat:

- `first_seen` asal dikekalkan;
- `last_seen` dikemas kini;
- status asal dikekalkan (tidak ditetapkan semula kepada `baru`).

Status hanya diubah melalui:

```bash
kimscan status <id> <fp> baru|diterima|dibetulkan
```

Perubahan status direkodkan dalam sesi itu dan dalam ledger kecil
`$XDG_DATA_HOME/kimscanning/status.json` supaya imbasan seterusnya bagi
`kind+target+fp` yang sama menggunakan status terkini, walaupun status
ditetapkan pada sesi yang lebih lama. Ledger ini juga membolehkan status
ditukar kembali kepada `baru`.

## Kamus rule (tanpa AI)

`rules/bm.yaml` memetakan `tool` + `rule` kepada tiga medan Bahasa Melayu:

- `apa` — apa yang dikesan;
- `bahaya` — mengapa ia berbahaya;
- `buat` — tindakan pembaikan.

Semua id dalam kamus disalin daripada keluaran sebenar gitleaks, semgrep,
dan trivy melalui `gate/gate.py`. Tiada id rekaan.

Jika rule tidak ada dalam kamus:

- `session.json` menyimpan `"explanation": null`;
- CLI memaparkan `[tiada penjelasan]`;
- `kimscan rules --missing` menyenaraikan `tool/rule` yang dilihat dalam
  sesi tetapi tiada dalam kamus, berserta bilangan dapatan dan sesi.

`kimscan rules` tanpa flag menyenaraikan semua entri kamus.

## Ujian

Ujian menggunakan `HOME` dan `XDG_DATA_HOME` sementara supaya konfigurasi
sebenar tidak disentuh:

```bash
bash kimscanning/test/run_tests.sh
```

Ujian membuat folder bersih dan folder bocor di bawah direktori sementara,
menjana kunci gaya AWS secara rawak dengan `tr -dc 'A-Z2-7'`, kemudian
menguji verdict, kod keluar, sesi, penjelasan, status carry-over, penolakan
web tanpa kebenaran, `rules --missing`, dan `doctor`.

Untuk menjalankan ujian dengan alat dari direktori sementara:

```bash
PATH=/tmp/opencode/bin:$PATH bash kimscanning/test/run_tests.sh
```

## Had v1

- Belum ada UI penuh skrin; ini alat baris perintah.
- Imbasan web/server sebenar memerlukan sasaran yang dibenarkan dan alat
  `nuclei`/`nikto`/`nmap`/`ssh-audit`. Jika alat tiada, gate akan memberi
  TIDAK LULUS kerana tiada bukti.
- KimScanning tidak mencipta rule id, tidak memanggil AI, dan tidak membuat
  verdict sendiri.
