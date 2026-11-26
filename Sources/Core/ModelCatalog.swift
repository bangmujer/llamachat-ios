import Foundation

/// Satu entri katalog model yang sudah dikurasi: dipastikan berformat
/// GGUF, arsitektur didukung llama.cpp v1.0.0, dan total pemakaian
/// RAM-nya (file + KV cache n_ctx 2048 + overhead) muat di bawah guard
/// 3,8 GB untuk iPhone 6 GB.
///
/// `exactSizeBytes` hanya diisi kalau ukuran byte pastinya terverifikasi
/// dari daftar file Hugging Face; kalau nil, ukuran tampil memakai
/// `sizeDisplay` dan verifikasi ukuran download memakai Content-Length
/// dari server, bukan angka hardcode.
///
/// Deskripsi (`tagline` + `strengths`) ditulis untuk membantu pengguna
/// memilih — bukan klaim benchmark; angka RAM adalah perkiraan.
public struct CatalogModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let quant: String
    public let fileName: String
    public let url: URL
    public let sizeDisplay: String
    public let exactSizeBytes: Int64?
    public let ramEstimateDisplay: String
    public let tagline: String
    public let strengths: String
    public let note: String?

    public init(
        id: String,
        name: String,
        quant: String,
        fileName: String,
        url: URL,
        sizeDisplay: String,
        exactSizeBytes: Int64?,
        ramEstimateDisplay: String,
        tagline: String,
        strengths: String,
        note: String?
    ) {
        self.id = id
        self.name = name
        self.quant = quant
        self.fileName = fileName
        self.url = url
        self.sizeDisplay = sizeDisplay
        self.exactSizeBytes = exactSizeBytes
        self.ramEstimateDisplay = ramEstimateDisplay
        self.tagline = tagline
        self.strengths = strengths
        self.note = note
    }
}

public enum ModelCatalog {
    public static let all: [CatalogModel] = [
        CatalogModel(
            id: "qwen3-4b-q4_k_m",
            name: "Qwen3 4B",
            quant: "Q4_K_M",
            fileName: "Qwen3-4B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!,
            sizeDisplay: "2,50 GB",
            exactSizeBytes: 2_497_280_256,
            ramEstimateDisplay: "±3,1 GB",
            tagline: "Pilihan utama. Serba bisa.",
            strengths: "Chat harian, Bahasa Indonesia & bahasa gaul, agent/tools, coding ringan.",
            note: "Rekomendasi utama untuk HP 6 GB. Model ini berpikir dulu (blok <think>) sebelum menjawab."
        ),
        CatalogModel(
            id: "qwen3-4b-q5_k_m",
            name: "Qwen3 4B",
            quant: "Q5_K_M",
            fileName: "Qwen3-4B-Q5_K_M.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q5_K_M.gguf")!,
            sizeDisplay: "2,89 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±3,5 GB",
            tagline: "Qwen3 4B dengan kualitas sedikit lebih baik.",
            strengths: "Chat harian, jawaban yang butuh lebih teliti.",
            note: "±400 MB lebih besar dari Q4_K_M dan sedikit lebih lambat. Satu-satunya upgrade yang masih muat di guard 3,8 GB."
        ),
        CatalogModel(
            id: "qwen3-4b-instruct-2507-abliterated-q4_k_m",
            name: "Qwen3 4B Instruct 2507 Abliterated",
            quant: "Q4_K_M",
            fileName: "Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/mradermacher/Qwen3-4B-Instruct-2507-abliterated-GGUF/resolve/main/Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf")!,
            sizeDisplay: "2,50 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±3,1 GB",
            tagline: "Qwen3 4B versi uncensored (abliterated).",
            strengths: "Chat harian seperti Qwen3 4B, tanpa perilaku refusal bawaan.",
            note: "Abliterasi huihui-ai atas Qwen3-4B-Instruct-2507 (arah refusal dihapus dari bobot; proof-of-concept, bukan jaminan refusal hilang total). Kemampuan sama dengan Qwen3 4B. Bukan model resmi Qwen."
        ),
        CatalogModel(
            id: "llama32-3b-heretic-abliterated-q4_k_m",
            name: "Llama 3.2 3B Heretic Abliterated",
            quant: "Q4_K_M",
            fileName: "Llama-3.2-3B-Instruct-heretic-ablitered-uncensored.Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/mradermacher/Llama-3.2-3B-Instruct-heretic-ablitered-uncensored-GGUF/resolve/main/Llama-3.2-3B-Instruct-heretic-ablitered-uncensored.Q4_K_M.gguf")!,
            sizeDisplay: "2,02 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,7 GB",
            tagline: "Llama 3B versi uncensored (ablasi Heretic).",
            strengths: "Chat umum, ringkasan, teks multibahasa, tanpa refusal bawaan.",
            note: "Ablasi metode Heretic atas Llama 3.2 3B Instruct. Model Meta: bila download ditolak (401), login Hugging Face dan setujui lisensi Meta dulu."
        ),
        CatalogModel(
            id: "llama32-3b-uncensored-q4_k_m",
            name: "Llama 3.2 3B Instruct Uncensored",
            quant: "Q4_K_M",
            fileName: "Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-uncensored-GGUF/resolve/main/Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf")!,
            sizeDisplay: "2,24 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,9 GB",
            tagline: "Llama 3B uncensored: ablasi + fine-tune tanpa filter.",
            strengths: "Chat umum, jawaban langsung tanpa refusal.",
            note: "Abliterasi + fine-tune data tanpa filter (chuanli11) — perilakunya bisa menyimpang dari model asli di luar soal refusal. Lisensi Meta (lihat entri Llama lain)."
        ),
        CatalogModel(
            id: "dolphin-llama32-3b-q4_k_m",
            name: "Dolphin 3.0 Llama 3.2 3B",
            quant: "Q4_K_M",
            fileName: "Dolphin3.0-Llama3.2-3B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Dolphin3.0-Llama3.2-3B-GGUF/resolve/main/Dolphin3.0-Llama3.2-3B-Q4_K_M.gguf")!,
            sizeDisplay: "2,02 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,7 GB",
            tagline: "Seri Dolphin: nurut ke system prompt pemiliknya.",
            strengths: "Chat umum, coding, matematika, function calling.",
            note: "Fine-tune uncensored cognitivecomputations — alignment ditentukan system prompt, bukan guideline bawaan. Lisensi Meta."
        ),
        CatalogModel(
            id: "dolphin-qwen25-3b-q4_k_m",
            name: "Dolphin 3.0 Qwen2.5 3B",
            quant: "Q4_K_M",
            fileName: "Dolphin3.0-Qwen2.5-3b-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Dolphin3.0-Qwen2.5-3b-GGUF/resolve/main/Dolphin3.0-Qwen2.5-3b-Q4_K_M.gguf")!,
            sizeDisplay: "1,93 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,6 GB",
            tagline: "Dolphin paling ringan, basis Qwen2.5.",
            strengths: "Chat harian, coding ringan, hemat RAM.",
            note: "Fine-tune uncensored cognitivecomputations, generasi Qwen2.5 (di bawah Qwen3 untuk obrolan umum)."
        ),
        CatalogModel(
            id: "gemma3-4b-heretic-q4_k_m",
            name: "Gemma 3 4B it Heretic",
            quant: "Q4_K_M",
            fileName: "gemma-3-4b-it-heretic-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/saidutta69/gemma-3-4b-it-heretic/resolve/main/gemma-3-4b-it-heretic-Q4_K_M.gguf")!,
            sizeDisplay: "2,50 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±3,2 GB",
            tagline: "Gemma 3 4B versi uncensored (ablasi Heretic).",
            strengths: "Mengikuti instruksi, ringkasan, teks multibahasa.",
            note: "Ablasi Heretic atas Gemma 3 4B it — refusal turun 98 ke 18 dari 100 prompt uji (bukan nol). Varian teks saja, kemampuan gambar tidak didukung aplikasi."
        ),
        CatalogModel(
            id: "qwen25-3b-q4_k_m",
            name: "Qwen2.5 3B Instruct",
            quant: "Q4_K_M",
            fileName: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!,
            sizeDisplay: "1,93 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,6 GB",
            tagline: "Generasi sebelumnya, kuat di coding.",
            strengths: "Coding, skrip, pertanyaan teknis.",
            note: "Untuk obrolan umum kualitasnya di bawah Qwen3 4B."
        ),
        CatalogModel(
            id: "llama32-3b-q4_k_m",
            name: "Llama 3.2 3B Instruct",
            quant: "Q4_K_M",
            fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sizeDisplay: "2,02 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,7 GB",
            tagline: "Buatan Meta, multibahasa.",
            strengths: "Chat umum, ringkasan, teks multibahasa.",
            note: "Model Meta: bila download ditolak (401), login Hugging Face dan setujui lisensi Meta dulu."
        ),
        CatalogModel(
            id: "llama32-1b-q4_k_m",
            name: "Llama 3.2 1B Instruct",
            quant: "Q4_K_M",
            fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            sizeDisplay: "0,81 GB",
            exactSizeBytes: 807_694_464,
            ramEstimateDisplay: "±1,5 GB",
            tagline: "Paling ringan dan cepat.",
            strengths: "Tanya jawab singkat, hemat RAM.",
            note: "Kemampuan terbatas — cocok untuk jawaban pendek saja. Lisensi Meta (lihat Llama 3B)."
        ),
        CatalogModel(
            id: "gemma3-4b-q4_k_m",
            name: "Gemma 3 4B it",
            quant: "Q4_K_M",
            fileName: "gemma-3-4b-it-text-only-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/tensorblock/gemma-3-4b-it-text-only-GGUF/resolve/main/gemma-3-4b-it-text-only-Q4_K_M.gguf")!,
            sizeDisplay: "2,49 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±3,2 GB",
            tagline: "Buatan Google, nurut instruksi dengan rapi.",
            strengths: "Mengikuti instruksi, ringkasan, teks multibahasa.",
            note: "Varian text-only — kemampuan gambar (vision) tidak didukung aplikasi."
        ),
        CatalogModel(
            id: "gemma3-1b-q4_k_m",
            name: "Gemma 3 1B it",
            quant: "Q4_K_M",
            fileName: "gemma-3-1b-it-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf")!,
            sizeDisplay: "0,81 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±1,5 GB",
            tagline: "Ringan, hemat RAM dan baterai.",
            strengths: "Chat singkat, pemakaian ringan.",
            note: "Kemampuan terbatas — cocok untuk jawaban pendek saja."
        ),
        CatalogModel(
            id: "smollm3-3b-q4_k_m",
            name: "SmolLM3 3B",
            quant: "Q4_K_M",
            fileName: "SmolLM3-3B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/HuggingFaceTB_SmolLM3-3B-GGUF/resolve/main/SmolLM3-3B-Q4_K_M.gguf")!,
            sizeDisplay: "1,92 GB",
            exactSizeBytes: nil,
            ramEstimateDisplay: "±2,6 GB",
            tagline: "Kecil tapi bertenaga, cepat.",
            strengths: "Chat harian, jawaban cepat.",
            note: "Konteks bawaan model ini panjang (128K), tapi aplikasi membatasi n_ctx sesuai Settings."
        ),
        CatalogModel(
            id: "deepseek-r1-distill-15b-q4_k_m",
            name: "DeepSeek R1 Distill Qwen 1.5B",
            quant: "Q4_K_M",
            fileName: "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf")!,
            sizeDisplay: "1,12 GB",
            exactSizeBytes: 1_117_321_312,
            ramEstimateDisplay: "±1,9 GB",
            tagline: "Spesialis penalaran (reasoning).",
            strengths: "Matematika, logika, soal berhitung.",
            note: "Model reasoning — berpikir panjang dalam blok <think> sebelum menjawab. Chat santai di bawah Qwen3 4B."
        ),
    ]
}
