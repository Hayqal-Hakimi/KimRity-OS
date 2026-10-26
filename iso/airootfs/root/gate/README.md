# KimRity Security Gate — v2 (repo · web · server)

Satu tool yang **memakai tool lain** untuk menyemak sesuatu projek dan
mengeluarkan keputusan **LULUS / LULUS BERSYARAT / TIDAK LULUS**.

Model AI **tidak** terlibat dalam keputusan. Verdict datang daripada
severity yang dilaporkan tool, mengikut peraturan dalam `gate.py`.

## Guna

```sh
python3 gate.py <sasaran> [--kind repo|web|server] [--scope FAIL] [--authorized] \
                [--out DIR] [--fail-on critical|high|medium] [--quiet]
```

Lalai: `--out gate-out`, `--fail-on high`. Jenis diteka jika `--kind` tiada
(folder → repo · URL → web · host/IP → server).

**Guard:** imbasan web/server **wajib** `--authorized` (kau sahkan kau ada
kebenaran menyasar). Jika `--scope fail` diberi, sasaran mesti ada dalam fail
itu (satu sasaran/CIDR setiap baris, `#` untuk komen) — sepadan §4.7 draf.

## Alat yang dijalankan

| Jenis | Alat | Cari |
|---|---|---|
| **repo** | `gitleaks` | rahsia dalam kod + sejarah git (sentiasa `high`) |
| | `semgrep --config p/default` | corak kod tak selamat (ikut severity semgrep) |
| | `trivy fs` | CVE pakej, secret, misconfig (ikut severity trivy) |
| **web** | `nuclei` | CVE/pendedahan template (severity nuclei) |
| | `nikto` | salah konfigurasi pelayan web (medium; header cadangan = low) |
| **server** | `nmap -sV -sC` | port terdedah (jadual risiko) + algoritma SSH/TLS lemah |
| | `ssh-audit` | hanya jika port 22 terbuka |

**Pelarasan ssh-audit (sengaja, didokumen):**
- `suspected as being backdoored` (kiraan NIST curve) → **low** — pendapat alat, bukan kerosakan
- `post-quantum` → **info** — anjuran masa depan
- `[fail]` lain (`broken SHA-1` dsb.) → **high**; `[warn]` lain → **medium**

**Jadual risiko port nmap:** 23/445/512-514/1433/3306/5432/6379/9200/27017 → high ·
21/3389/5900 → medium · 111 → low.

Semua tiga mesti ada. Tool gagal = **tiada bukti = TIDAK LULUS**.

## Peraturan verdict

- ada isu ≥ `--fail-on` (lalai `high`) → **TIDAK LULUS** (exit 1)
- tiada high, tetapi ada `medium` → **LULUS BERSYARAT** (exit 0)
- tiada isu → **LULUS** (exit 0)

## Keluaran

- `gate-out/gate.json` — bukti penuh: versi tool, commit, semua findings, verdict
- `gate-out/laporan.md` — ringkasan untuk manusia (Bahasa Melayu)

## Ujian yang sudah dijalankan

| Jenis | Sasaran ujian | Verdict | Findings |
|---|---|---|---|
| repo | Kunci AWS rawak + SQLi + `flask==0.5` | TIDAK LULUS | 18 (11 high, 6 medium, 1 low) |
| repo | `os-security-ai` (bersih) | LULUS | 0 |
| web | `http://127.0.0.1:8080` (`.git/config` terdedah) | LULUS BERSYARAT | 9 (4 medium, 5 low) — nuclei kesan `.git/config` |
| server | `127.0.0.1` (listener 3306 palsu + sshd) | TIDAK LULUS | 24 (3 high: port 3306, 2× hmac-sha1) |
| guard | web/server tanpa `--authorized` | ditolak, exit 1 | — |
| guard | sasaran luar `--scope` | ditolak, exit 1 | — |
| guard | sasaran dalam `--scope` | diterima | — |

Pengesanan silang: kunci AWS dikesan oleh **gitleaks**, **semgrep** dan
**trivy** secara berasingan — tiga enjin bebas, bukan satu.

## Had v2

- Belum ada baseline (isu lama yang diterima) — semua isu dikira setiap kali
- `semgrep p/default`, `trivy` dan `nuclei` perlukan rangkaian kali pertama (rule/DB)
- Laporan belum ditandatangani/disahkan hash
- `nuclei` penuh (13,619 template) ambil beberapa minit setiap imbasan
- Server: hanya `--top-ports 1000` (bukan 65,535)
- Web: `nikto` had 10 minit
