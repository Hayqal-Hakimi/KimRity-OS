# Kit Prompt — bina OS Security+AI (Langkah 1 sahaja)

*Dibuat 14 Okt 2026. Untuk dipakai dengan chatbot (Claude) yang sudah tahu konteks projek ini.*

**Matlamat fasa ini:** mesin boleh dipasang semula dari skrip sendiri, diuji dalam VM. Bukan ISO, bukan broker, bukan agent AI.

---

## A. PROMPT PEMBUKA — paste setiap kali mula chat baharu

```
KONTEKS PROJEK — kemas kini skop (guna ini, bukan versi lama).

Projek: OS Linux sendiri (Arch + Hyprland) untuk kegunaan SAYA SENDIRI — stesen
kerja harian + makmal belajar cybersec.

KEPUTUSAN SKOP (14 Okt 2026):
- Fasa ini GUNA SENDIRI sahaja. Bukan untuk diedarkan.
- ISO / archiso TIDAK DIPERLUKAN sekarang. Jangan cadangkan.
- Matlamat fasa ini: mesin saya boleh dipasang semula dari skrip saya sendiri.
- Kerja seterusnya: skrip install + dotfiles, diuji dalam VM dahulu.

BATASAN MESIN SAYA (jangan cadang di luar ini):
- i5-4590 (4 teras), RAM 7.2 GiB → VM maksimum 2.5 GB RAM
- Omarchy (Arch + Hyprland) sudah terpasang; Windows di partition lain
- JANGAN sentuh partition Windows (sda3, sda4) — langsung tidak
- Semua ujian dalam VM (KVM tersedia). Mesin harian saya mesti kekal boleh guna.

PERATURAN CARA KERJA KAU (wajib dipatuhi):
1. SATU langkah sahaja setiap balasan. Tunggu output saya.
2. Format setiap langkah: (a) tujuan, (b) arahan tepat, (c) apa yang sepatutnya
   saya nampak kalau betul, (d) apa tanda ia gagal, (e) apa yang perlu saya
   hantar balik kepada kau.
3. Jangan tulis skrip penuh untuk saya. Ajar dan tunjuk arahan; saya taip sendiri.
4. Untuk setiap arahan luar biasa, sebut sumbernya (halaman Arch Wiki / Hyprland
   Wiki) supaya saya boleh sahkan sendiri.
5. Kalau kau tak pasti tentang mesin saya, TANYA — jangan andaikan.
6. Jangan bawa balik senibina penuh yang lama (broker kelulusan, agent AI,
   environment cermin, 4 tahap kebenaran, ISO). Itu fasa lain. Sebut hanya kalau
   saya minta.
7. Sebelum mana-mana langkah berisiko, beritahu cara undur (snapshot VM / apa).

Kalau kau faham, jawab ringkas sahaja:
(1) ulang matlamat fasa ini dalam satu ayat,
(2) senaraikan apa yang kau rasa "langkah 1",
(3) tanya maksimum 5 soalan tentang mesin saya.
Jangan beri arahan lagi.
```

---

## B. PROMPT PUSINGAN KERJA — selepas setiap langkah

```
Langkah seterusnya. SATU langkah sahaja, ikut format (a)–(e).
```

## C. PROMPT PEMBETULAN — bila dia langgar peraturan

| Pelanggaran | Paste ini |
|---|---|
| Beri banyak langkah | `Kau beri lebih daripada satu langkah. Potong: beri hanya langkah pertama, dan tunggu output saya.` |
| Beri skrip penuh | `Kau bagi skrip penuh. Aku nak arahan satu-satu — aku taip sendiri. Buang skrip, beri arahan.` |
| Tak sebut sumber | `Untuk arahan itu, sebut halaman Arch Wiki / Hyprland Wiki mana yang menyokongnya supaya aku boleh sahkan.` |
| Andaian tentang mesin aku | `Itu andaian. Tanya aku dulu, atau beri arahan untuk aku sahkan sendiri.` |
| Bawa balik senibina lama | `Itu fasa lain. Kita hanya langkah 1: skrip install + dotfiles. Teruskan.` |

---

## D. PROMPT BILA STUCK — hantar ini (jangan hantar ringkasan)

```
STUCK. Maklumatnya:
- Langkah yang aku cuba: ...
- Arahan tepat yang aku jalankan: ...
- Output penuh (paste mentah, bukan ringkasan): ...
- Apa yang aku JANGKAKAN: ...
- Apa yang berlaku sebenarnya: ...
- Perubahan terakhir sebelum ia berfungsi: ...

Beri SATU langkah seterusnya untuk mengesahkan hipotesis — bukan lima.
```

**Peraturan penting:** hantar output mentah. Ringkasan boleh menyembunyikan punca. (Ini prinsip yang sama dalam senibina OS ini: broker tunjuk arahan sebenar, bukan ringkasan AI.)

---

## E. PROMPT SEMAK & ELAK DRIFT — setiap ~5 langkah

```
Ringkaskan status:
(1) apa yang sudah siap DAN disahkan,
(2) apa yang belum,
(3) keputusan yang aku telah buat,
(4) apa yang kau TIDAK pasti / andaian kau.
Jangan tambah langkah baharu dalam ringkasan ini.
```

---

## F. PROMPT UJIAN "BOLEH DIPASANG SEMULA?"

```
Senaraikan ujian untuk membuktikan mesin ini boleh dipasang semula dari skrip
dari kosong. Beri ujian paling kecil dahulu, satu demi satu.
```

---

## G. CARA KAU SAHKAN DIA BERI MAKLUMAT BETUL

Jangan terima dakwaan pakej/flags tanpa semak — chatbot boleh reka nama pakej.

| Arahan | Guna untuk |
|---|---|
| `pacman -Si <pakej>` | Sahkan pakej wujud + repo mana (extra / core / AUR) |
| `pacman -Ss <kata>` | Cari pakej ikut nama/keterangan |
| `pacman -Qo <fail>` | Fail itu milik pakej mana |
| Arch Wiki + Hyprland Wiki | Banding setiap config bukan-asas |

Tanda amaran:
- Dia sebut "ada dalam AUR" → **bukan rasmi**; kena kekalkan sendiri
- Cadangan `--overwrite` atau `-Sy` atas **sistem harian** → tolak
- Dia sebut versi pakej → sahkan dengan `pacman -Si`, jangan percaya angka
- Dia "ingat" sesuatu tentang mesin kau → sahkan, jangan percaya ingatan chat

---

## H. LOG SESI — wajib, sebab ingatan chatbot hilang

Simpan fail `langkah-log.md` (di rumah kod projek). Setiap sesi, tambah:

```
## <tarikh>
- Buat: <apa>
- Bukti: <output penting / hasil ujian>
- Keputusan: <apa yang diputuskan dan kenapa>
- Belum: <apa yang tinggal>
- Blocker: <kalau ada>
```

Bila mula chat baharu: paste **PROMPT A + 20 baris terakhir log**.

---

## I. JANGAN TANYA BENDA INI (punca skop meletup)

| Jangan tanya | Sebab |
|---|---|
| "Reka senibina OS ni" | Dia akan kembangkan skop; kau sudah ada senibina |
| "Tulis skrip penuh untuk aku" | Kau tak belajar apa-apa; dan kau sendiri mahu taip sendiri |
| "Macam mana nak bagi orang lain guna" | Fasa 2, opsyenal, belum |
| "Boleh tak buat ini serentak dengan itu" | Satu benda satu masa |
| "Tolong semak semua yang aku buat setakat ini" | Audit menyeluruh = kerja besar; tanya benda spesifik |

---

## J. BILA HANTAR KE HERMES

Hantar bila: (1) stuck lebih 2 percubaan, (2) chatbot dan kau tak sepakat tentang fakta teknikal, (3) keputusan skop berubah, (4) langkah 1 siap (untuk direkod dalam vault).
