# KimAI v1 (rangka kerangka)

KimAI v1 ialah servis latar belakang (broker) setempat yang menyimpan baris gilir
kelulusan untuk alat lain seperti **KimScanning** dan **KimLogPipe**. Ia berjalan
di latar hadapan apabila dimulakan dan hanya bertindak apabila diminta
(*on-demand*). Tiada pemantauan latar, tiada pengundian log, tiada pemasa, dan
tiada panggilan rangkaian dalam v1.

## Keperluan

- Python 3 (hanya pustaka standard)
- Linux dengan soket Unix dan `SO_PEERCRED`

## Permulaan pantas

```bash
chmod +x kimai/kimai

# Terminal 1: jalankan daemon di latar hadapan
./kimai/kimai start

# Terminal 2: semak status
./kimai/kimai status
```

Untuk ujian berasingan daripada sesi pengguna sebenar:

```bash
HOME=<direktori-sementara> \
XDG_DATA_HOME=<direktori-sementara>/.local/share \
XDG_RUNTIME_DIR=<direktori-sementara>/run \
bash kimai/test/run_tests.sh
```

## Laluan socket

KimAI memilih laluan socket mengikut urutan berikut:

1. `$XDG_RUNTIME_DIR/kimai.sock` jika direktori itu wujud dan boleh ditulis.
2. `/run/user/$(id -u)/kimai.sock` jika direktori itu wujud dan boleh ditulis.
3. `~/.cache/kimai/kimai.sock` sebagai sandaran terakhir.

Fail socket ditetapkan kepada mod **0600**. Daemon menyemak UID rakan sebaya
melalui `SO_PEERCRED` dan menolak sambungan daripada UID yang berbeza, walaupun
kebenaran sistem fail sudah menghalangnya.

## Protokol

Protokol ialah **JSON bersempadan baris baharu** melalui soket Unix. Setiap
sambungan boleh menghantar satu atau lebih permintaan; setiap baris ialah satu
objek JSON.

Permintaan:

```json
{"id":"<sebarang>","op":"<nama>","args":{...}}
```

Respons berjaya:

```json
{"id":"<sama>","ok":true,"result":{...}}
```

Respons gagal:

```json
{"id":"<sama>","ok":false,"error":"<mesej>"}
```

`id` dipantulkan semula tanpa perubahan. `args` boleh ditinggalkan atau `{}`
jika op tidak memerlukannya. Baris kosong diabaikan.

## Operasi v1

| Op | Args | Keputusan |
| --- | --- | --- |
| `ping` | – | `{"pong":true,"version":"0.1.0"}` |
| `status` | – | `{"version","uptime_s","ai_enabled","pending_approvals","socket"}` |
| `ask` | `{"prompt":"..."}` | `{"answer":"..."}` jika `command` dikonfigurasi; jika tidak, ralat `AI belum dikonfigurasi` |
| `approve.request` | `{"tool","action","args","risk","reason"}` | `{"request_id":"<id>"}` |
| `approve.list` | – | `{"pending":[...],"recent":[...]}` |
| `approve.decide` | `{"request_id","decision":"lulus\|tolak","note":""}` | `{"request_id","decision","note"}` |
| `shutdown` | – | `{"shutdown":true}` (digunakan oleh `kimai stop`) |

Op yang tidak dikenali mengembalikan `ok:false` dengan mesej yang jelas.

### `ask`

Secara lalai tiada AI dikonfigurasi, jadi `ask` memulangkan:

```json
{"id":"...","ok":false,"error":"AI belum dikonfigurasi"}
```

Jika `~/.config/kimai/config.toml` mempunyai kunci `command` (di peringkat atas
atau dalam jadual `[ai]`), KimAI menjalankan perintah **tempatan** itu, menghantar
prompt melalui `stdin`, dan memulangkan `stdout` sebagai `answer`. Tiada klien
web atau API rangkaian digunakan oleh KimAI. Lihat `kimai/config.example.toml`.

### Kelulusan

`approve.request` menyimpan permintaan dalam ingatan dan menambah satu baris ke
fail rekod. `approve.decide` merekodkan keputusan dan menambah satu lagi baris.
Permintaan yang belum diputuskan muncul dalam `pending`; keputusan terkini muncul
dalam `recent`.

## Rekod tambah-sahaja

Setiap permintaan dan keputusan ditambah ke:

```
$XDG_DATA_HOME/kimai/approvals.jsonl
```

Jika `XDG_DATA_HOME` tidak ditetapkan, laluannya ialah
`~/.local/share/kimai/approvals.jsonl`. Fail ini **hanya ditambah** dan tidak
pernah ditulis semula atau dikosongkan. Setiap baris ialah satu objek JSON:

```json
{"ts":"...","request_id":"...","tool":"...","action":"...","args":{},"risk":"...","reason":"...","decision":null,"note":""}
```

Baris permintaan mempunyai `decision:null`; baris keputusan mempunyai
`decision:"lulus"` atau `"tolak"` serta `note`.

## Cara KimScanning meminta kelulusan

KimScanning boleh membuka sambungan baharu, menghantar satu permintaan, membaca
satu respons, dan menutup sambungan:

```python
import json
import os
import socket

sock_path = os.path.join(os.environ["XDG_RUNTIME_DIR"], "kimai.sock")
request = {
    "id": "imbas-001",
    "op": "approve.request",
    "args": {
        "tool": "KimScanning",
        "action": "imbas-direktori",
        "args": {"sasaran": "/home/pengguna/MuatTurun"},
        "risk": "sederhana",
        "reason": "Mengesan fail mencurigakan sebelum tindakan selanjutnya",
    },
}

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(5)
client.connect(sock_path)
client.sendall((json.dumps(request) + "\n").encode("utf-8"))
response = json.loads(client.makefile("rb").readline())
client.close()

print(response)
# {"id":"imbas-001","ok":true,"result":{"request_id":"req-..."}}
```

KimScanning kemudian menyimpan `request_id` itu dan boleh menyemak
`approve.list` atau menunggu pengguna memutuskan melalui:

```bash
./kimai/kimai approve list
./kimai/kimai approve yes req-... --note "disemak secara manual"
./kimai/kimai approve no  req-... --note "sasaran tidak dibenarkan"
```

## Arahan klien

```bash
kimai start
kimai stop
kimai status
kimai ask "<prompt>"
kimai approve list
kimai approve yes <request_id> [--note "..."]
kimai approve no  <request_id> [--note "..."]
```

Jika daemon tidak berjalan, semua arahan klien mencetak `KimAI tidak berjalan`
dan keluar dengan kod bukan sifar. Klien tidak akan menunggu atau memulakan
daemon secara automatik.

`kimai stop` menghantar op `shutdown`, kemudian membuang fail socket. Daemon
juga membuang socket semasa keluar secara normal (SIGINT/SIGTERM).

## Konfigurasi

Salin `kimai/config.example.toml` ke `~/.config/kimai/config.toml` jika mahu
mengaktifkan `ask` dengan perintah tempatan. Jangan masukkan klien rangkaian
dalam konfigurasi jika mahu mematuhi sifat v1.

## Nota tentang pemantauan cron

Pemantauan berkala melalui cron **boleh** dilakukan pada masa hadapan (contohnya
menjalankan KimScanning setiap jam dan meminta kelulusan melalui KimAI), tetapi
ia **sengaja tidak diaktifkan secara lalai** dalam v1. KimAI v1 hanya bertindak
apabila alat lain memanggilnya.
