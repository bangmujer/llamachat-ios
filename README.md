# LlamaChat — LLM lokal di iOS (llama.cpp, full offline)

Chat app SwiftUI yang menjalankan LLM lokal lewat llama.cpp. Tanpa API
pihak ketiga. Inference di background, Metal, full offload GPU.

**Status: Fase 2 + Agent + Katalog Model + Web Tools.** Di atas Fase A–D: regenerate/edit/copy,
penghitung token + bar konteks, dark mode, haptik, Markdown blok
(tabel, blok kode, lipat pesan panjang), dan agent tools (waktu, info
perangkat, kalender, pengingat, kontak, Shortcut, cari di internet,
buka halaman web) dengan orkestrasi tool-call 2 langkah dan
konfirmasi untuk tool tulis/eksternal. Tool internet nonaktif secara
default (query dikirim ke mesin pencari) dan memakai DuckDuckGo HTML +
fallback Wikipedia tanpa API key. Model Manager punya katalog model
terkurasi (9 model, lengkap dengan keterangan kegunaan) dan
downloader segmen paralel ala download manager (koneksi 1–60, maks 2
file bersamaan, tahan jeda/gagal). Redesign UI/UX menyeluruh belum
dikerjakan (terakhir, sesuai arahan pengguna). Lihat bagian "Peta
fase" di bawah.

## Pin llama.cpp — baca ini dulu

- **Tag: `v1.0.0`** (rilis stabil pertama llama.cpp, 13 November 2026).
  Commit tag: `b1b770d90d94cad9e9ea5b993bdbc383a522fb28`.
- Integrasi: `llama.xcframework` hasil `build-xcframework.sh` dari repo
  `ggml-org/llama.cpp`, argumen `ios-device` saja (device arm64, tanpa
  simulator). Script upstream membangun dengan `GGML_METAL=ON` dan
  `GGML_METAL_EMBED_LIBRARY=ON` sebagai default — tidak ada flag tambahan
  yang disembunyikan di workflow.
- **Tidak ada** SwiftPM wrapper / CocoaPod pihak ketiga.
- **Tidak ada** file `llama-sampling.h` di v1.0.0. API sampling
  (`llama_sampler_chain_*`, `llama_sampler_init_*`,
  `llama_sampler_sample`) hidup di `include/llama.h` bagian "Sampling API".
  Jangan menambahkan `#import "llama-sampling.h"` — file itu tidak ada
  dan build akan gagal. Semua nama fungsi C di kode sudah dicek langsung
  terhadap `include/llama.h` v1.0.0 sebelum ditulis; tempat yang masih
  bergantung pada spelling impor C Swift ditandai `VERIFY AGAINST
  GENERATED INTERFACE` di komentar kode.
- `llama.h` v1.0.0 menghapus API deprecated lama (termasuk
  `llama_set_warmup`). Jangan memakai tutorial lama yang masih
  memanggil `llama_sample_*` — fungsi-fungsi itu tidak ada; sampling
  harus lewat `llama_sampler_chain`.

## Persyaratan

- iOS 17.0+ (deployment target 17.0 — SwiftData dipakai mulai Fase D,
  dan SwiftData membutuhkan iOS 17+).
- Swift 5.9+. Tanpa Storyboard. Device arm64 saja (iPhone); simulator
  tidak didukung — xcframework hanya dibangun untuk `iphoneos`.
- Xcode di CI: runner `macos-15`, Xcode terbaru yang tersedia di runner,
  XcodeGen via Homebrew. Tidak ada Mac lokal yang dibutuhkan untuk
  pola ini; build jalan di GitHub Actions, IPA unsigned untuk TrollStore.
- Model: file GGUF. Model uji yang disepakati: Qwen3 3B.
  **Catatan jujur:** nama repo/file GGUF resmi yang persis untuk
  "Qwen3-3B" belum terverifikasi saat Fase A ditulis. Engine TIDAK
  meng-hardcode nama file, jumlah layer, atau ukuran file: ia memakai
  file `.gguf` pertama di `Application Support/Models/`, membaca
  metadata runtime (`llama_model_n_layer`, `n_head_kv`, `n_ctx_train`,
  dst.), dan menghitung estimasi memori dari metadata itu. Bawa file
  GGUF Qwen3 pilihanmu sendiri dan sebutkan repo/file persisnya saat
  review Fase A supaya README ini bisa mencatat URL yang terverifikasi.

## Struktur

```
App/
  LlamaChatApp.swift        @main; memory-warning -> engine
Features/Chat/
  ChatView.swift / ChatViewModel.swift / MessageBubble.swift / ComposerBar.swift
Core/
  LlamaEngine.swift         actor; semua pointer C hidup di sini
  LlamaEngine+Generation.swift  prefill -> decode loop, UTF-8 incremental
  ModelLoader.swift         locate + validasi GGUF (tanpa download)
  ChatTemplate.swift        template manual fallback (pure Swift)
  Sampler.swift             SamplingParameters + sampler chain
Models/
  ChatMessage.swift / Conversation.swift / ModelDescriptor.swift
Resources/
  Info.plist                (digenerate ulang XcodeGen; kunci di project.yml)
project.yml                 sumber kebenaran proyek (XcodeGen)
.github/workflows/build-ipa.yml
scripts/build-xcframework.sh  build xcframework di Mac lokal (opsional)
```

## Konfigurasi Xcode (lengkap, tanpa langkah GUI yang disembunyikan)

Proyek di-generate dari `project.yml` dengan XcodeGen. Jangan mengedit
`.xcodeproj` hasil generate — ia tidak di-commit dan akan ditimpa.

| Pengaturan | Nilai | Keterangan |
|---|---|---|
| Deployment target | iOS 17.0 | `IPHONEOS_DEPLOYMENT_TARGET: 17.0`, `deploymentTarget.iOS: 17.0` |
| Swift | 5.9 | `SWIFT_VERSION: 5.9` |
| Bundle ID | `com.bangmujer.llamachat` | `bundleIdPrefix: com.bangmujer` |
| Product name | LlamaChat | — |
| Signing | Tidak ada | `CODE_SIGNING_ALLOWED: NO`, `CODE_SIGNING_REQUIRED: NO`, `CODE_SIGN_IDENTITY: ""`. IPA unsigned untuk TrollStore, sama seperti proyek MDM. |
| Bridging header | **Tidak ada** | `llama.xcframework` membawa module map (`framework module llama`, umbrella Headers, link c++/Accelerate/Metal/Foundation). Swift cukup menulis `import llama`. Tidak ada `SWIFT_OBJC_BRIDGING_HEADER`. |
| Framework Search Paths | Otomatis via XcodeGen | Deklarasi `dependencies: - framework: ThirdParty/llama.xcframework, embed: true` di `project.yml`. Tidak ada search path manual. |
| Embed framework | Ya | `embed: true`, supaya `llama.framework` ikut di dalam `.app` / IPA. |
| Background modes | `fetch` | Hanya untuk download model background di Fase C. Fase A tidak memakai jaringan. |
| App Transport Security | Default (ketat) | Tidak dilonggarkan. Download model Fase C memakai HTTPS standar. |

Pelajaran dari proyek MDM yang diterapkan di sini: XcodeGen **menimpa**
`Info.plist` di `info.path` setiap generate, jadi kunci custom wajib
dideklarasikan di `info.properties` di `project.yml`, bukan hanya di
file `Info.plist` tulisan tangan.

## Build

### Di GitHub Actions (pola utama, tanpa Mac)

1. Push repo ini ke branch `main` (lihat "Langkah manual" di bawah).
2. Workflow `.github/workflows/build-ipa.yml` berjalan otomatis:
   - clone `llama.cpp` di tag `v1.0.0` (shallow, `--depth 1`),
   - `./build-xcframework.sh ios-device` -> `build-apple/llama.xcframework`,
   - salin ke `ThirdParty/llama.xcframework`,
   - `xcodegen generate`,
   - `xcodebuild ... -sdk iphoneos archive` unsigned,
   - kemas IPA, upload artifact `llamachat-ios-unsigned-ipa`.
3. Unduh artifact dari halaman run, unzip, share `.ipa` ke TrollStore.

Waktu build xcframework jauh lebih lama dari build app biasa (kompilasi
C++ llama.cpp + Metal). Jangan menganggap workflow macet sebelum log
menunjukkan kegagalan; baca log untuk error persisnya.

### Di Mac lokal (opsional)

```sh
brew install cmake xcodegen
./scripts/build-xcframework.sh   # clone v1.0.0, build ios-device, salin ke ThirdParty/
xcodegen generate
xcodebuild -project LlamaChat.xcodeproj -scheme LlamaChat -configuration Release -sdk iphoneos build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

`ThirdParty/` dan `*.gguf` di-`.gitignore`: xcframework dan model tidak
di-commit.

## Memori — cara engine memutuskan boleh load atau tidak

Sebelum load penuh, engine melakukan probe `vocab_only` untuk membaca
metadata, lalu menghitung:

```
KV     = n_ctx * n_layer * n_head_kv * (n_embd / n_head) * 2 (K+V) * 2 byte (f16)
total  = ukuran file GGUF + KV + overhead 300 MB
```

Lalu menolak load (`AppError.outOfMemory`, pesan Bahasa Indonesia)
kalau `total > memori tersedia (os_proc_available_memory())` ATAU
`total > batas aman`: 3,8 GB di device <= 6 GB RAM (dilonggarkan atas
persetujuan pengguna 2026-11-25 untuk Qwen3-4B Q4_K_M; sebelumnya
2,6 GB), 3,5 GB di device 8 GB. Angka-angka ini di-log di konsol
saat load supaya bisa diaudit.

Contoh ilustratif (bukan hardcode; angka nyata dibaca dari model):
n_layer=36, n_head_kv=2, head_dim=128 -> KV 2048 konteks = ~72 MB,
KV 4096 konteks = ~144 MB. File Q4_K_M 3B sekitar 1,9 GB + overhead
300 MB membuat total di kisaran 2,3 GB — inilah alasan default
`n_ctx` di device <= 6 GB (termasuk iPhone 15, 6 GB) adalah **2048**,
bukan 4096. Naikkan ke 4096 per-model di Fase C hanya kalau guard
memori mengizinkan di device-mu.

Saat memory warning iOS, app memanggil `handleMemoryWarning()` yang
mengosongkan KV cache (`llama_memory_clear`). Generation yang sedang
berjalan tetap harus dihentikan lewat cancellation Task-nya.

## Keputusan desain yang tidak obvious

1. **Actor, bukan DispatchQueue manual.** Semua state C hidup di
   `LlamaEngine` (actor). ViewModel/View tidak pernah memegang pointer.
   Komunikasi ke UI lewat `AsyncStream<GenerationEvent>`.
2. **Probe vocab-only sebelum estimasi.** Jumlah layer tidak diketahui
   sebelum metadata dibaca; menebaknya dari nama file adalah bug.
3. **Batch dibangun dari `llama_batch_init` dan diisi per-chunk.**
   Prefill di-chunk maksimal 512 token (atau `n_batch` aktual, mana
   yang lebih kecil) supaya cancellation bisa menyela prompt panjang.
   Posisi (`pos`) dilacak manual (`nPast`) — jangan andalkan posisi
   otomatis saat batch diisi sebagian.
4. **`llama_sampler_sample` sudah accept.** Jangan panggil
   `llama_sampler_accept` lagi; repeat penalty akan menghitung token
   yang sama dua kali.
5. **Detokenisasi incremental dengan buffer byte.** Piece per token
   dari `llama_token_to_piece` diakumulasi; hanya prefix UTF-8 valid
   yang di-emit. Karakter multi-byte yang terpotong antar token ditahan,
   bukan di-render sebagai `�`.
6. **Context overflow = berhenti dengan pesan, bukan truncate diam-diam.**
   Prompt yang melebihi `n_ctx` ditolak sebelum decode; decode yang
   kehabisan slot KV (`llama_decode` mengembalikan 1) mengakhiri stream
   dengan `.done(.contextOverflow)`. Context shift belum ada.
7. **Cancellation bukan error.** Stop menghasilkan `.done(.cancelled)`,
   bukan `.failed`. `AppError.cancelled` hanya untuk pembatalan saat load.
8. **Template tidak di-parse sebagai Jinja di Swift (keputusan Fase C).**
   `llama_chat_apply_template` di v1.0.0 "does not use a jinja parser"
   dan hanya mendukung template bawaan tertentu, jadi `.auto` mendeteksi
   keluarga template dari penanda khas di template metadata model
   (`ChatTemplate.detect`) lalu render dengan string builder Swift.
   Pengguna bisa meng-override per-model di Settings.

## Langkah manual yang harus dilakukan sendiri

1. **Buat repo GitHub kosong** (nama yang diusulkan: `llamachat-ios`,
   owner `bangmujer`, branch `main`) dan push file-file Fase A ini.
   File belum di-push dari workspace ini; konfirmasi nama repo dulu
   sebelum push.
2. **Tunggu workflow selesai**, unduh artifact `llamachat-ios-unsigned-ipa`,
   install lewat TrollStore di iPhone 15 (iOS 27).
3. **Siapkan satu file GGUF Qwen3** di iPhone (unduh di Files / terima
   lewat AirDrop / share sheet). Di app Fase A: **Pilih Model (.gguf)**
   untuk menyalinnya ke `Application Support/Models/`. Tidak ada cara
   lain yang didukung di Fase A; download dari URL datang di Fase C.
4. **Muat & Generate**, lalu kerjakan checklist di bawah dan laporkan
   hasilnya (termasuk angka-angka dari log di layar) sebelum Fase B.

## Checklist verifikasi Fase A

- [ ] App launch tanpa model: status Idle, tombol "Muat & Generate"
      menampilkan error model tidak ditemukan dalam Bahasa Indonesia,
      tanpa crash.
- [ ] Pilih model .gguf dari Files: status menampilkan nama + ukuran file.
- [ ] Muat & Generate: log menampilkan estimasi memori (file/KV/overhead/
      total/tersedia/batas aman), `n_ctx` aktual, `n_batch` aktual, dan
      500 karakter pertama template chat bawaan model (atau pesan
      "tidak membawa chat template").
- [ ] Hasil generation muncul bertahap di kotak Hasil (bukan sekaligus
      di akhir), dalam Bahasa Indonesia, satu kalimat tentang fotosintesis
      (atau jawaban koheren setara — nilai kualitas jawaban model, bukan
      bukti integration; yang dibuktikan di sini adalah streaming +
      berhenti di EOT).
- [ ] Kecepatan tampil sebagai token/detik, dan log akhir menampilkan
      angka perf llama.cpp (prompt token/ms, generate token/ms).
- [ ] Tekan **Stop** saat generating: teks berhenti dalam waktu yang
      terasa seketika, status menjadi "Stop diminta" lalu "Selesai:
      cancelled", tanpa crash dan tanpa token yang terus mengalir.
- [ ] Jalankan Muat & Generate kedua kalinya tanpa restart app:
      berhasil, tanpa leak yang terlihat (tidak ada crash / jetsam).
- [ ] Hapus model dari folder Models (via Files, hapus dari app lain
      tidak didukung di Fase A — gunakan picker untuk menimpa) lalu
      jalankan lagi: error model tidak ditemukan, bukan crash.
- [ ] (Opsional, Mac) `xcodebuild` lokal berhasil untuk `iphoneos`;
      simulator sengaja tidak diuji.

## Peta fase

- **Fase A (selesai):** proyek + xcframework + `LlamaEngine` + harness.
  Harness dihapus di Fase B; engine-nya tidak berubah kecuali dua
  perbaikan compile dari log CI run #1.
- **Fase B (ini):** ChatView + streaming (throttle ~20 fps) + stop +
  system prompt (UserDefaults, berlaku untuk jawaban berikutnya).
  Multi-turn = render ulang seluruh riwayat tiap giliran, karena engine
  mengosongkan KV cache setiap generation selesai.
- **Fase B (ini):** ChatView + streaming (throttle ~20 fps) + stop +
  system prompt (UserDefaults).
- **Fase C (ini):** Settings (parameter sampling per-model tersimpan di
  UserDefaults, template picker dengan auto-detect dari metadata model,
  system prompt), Model Manager (daftar + ukuran, hapus, impor Files,
  download background URLSession dengan progress/resume/verifikasi
  ukuran — hanya dari URL yang dimasukkan pengguna, HTTPS saja).
  Perbaikan 2026-11-26: tipe dokumen GGUF dideklarasikan di Info.plist
  (`org.ggml.gguf`, conform `public.data`) supaya Files menawarkan
  "Buka di LlamaChat" dan picker tidak menonaktifkan file .gguf;
  import memvalidasi magic GGUF dan menghapus salinan yang bukan GGUF.
  Perbaikan lanjutan di hari yang sama: picker memakai HANYA `.data`
  karena pencocokan UTI kustom .gguf di picker tidak bisa diandalkan;
  Settings menampilkan status dukungan .gguf dari Info.plist build
  yang terpasang untuk diagnosis.
- **Fase D:** Persistensi SwiftData + multi-conversation (model
  `Conversation`/`StoredMessage`, daftar percakapan di sheet ChatView,
  restore percakapan terakhir, hapus percakapan; simpan pada titik
  diskrit, bukan per flush token).
- **Fase 2 + Agent:** regenerate/edit/copy (menu tekan-lama),
  penghitung token + bar konteks (event `.usage` dari engine),
  dark mode (Skema warna di Settings), haptik, Markdown ringan
  (inline-only di bubble asisten). Agent: 7 tools (waktu, info
  perangkat, jadwal kalender, buat acara, buat pengingat, cari
  kontak, jalankan Shortcut) dengan parser JSON tool-call,
  konfirmasi untuk tool tulis/eksternal, dan izin sistem
  (Kalender/Pengingat/Kontak) di `project.yml`. Tidak ada akses ke
  isi aplikasi lain dan tidak ada ubah pengaturan sistem langsung —
  batas sandbox iOS.

Setiap fase berhenti untuk review sebelum fase berikutnya dimulai.
