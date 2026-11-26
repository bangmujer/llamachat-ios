import Foundation

/// Pemisah blok penalaran `<think>...</think>` dari jawaban model.
///
/// Qwen3 (mode thinking bawaan) mengeluarkan penalarannya di dalam tag
/// `<think>` SEBELUM jawaban akhir. Menampilkan blok itu mentah-mentah
/// membuat bubble jawaban penuh teks penalaran berbahasa Inggris dan
/// memakan hampir seluruh budget token, sehingga jawaban akhirnya
/// terpotong di tengah kalimat. Blok think juga TIDAK boleh ikut
/// dikirim kembali sebagai riwayat: ia menghabiskan konteks (n_ctx)
/// tanpa menambah informasi untuk giliran berikutnya.
///
/// Desainnya: isi pesan mentah tetap disimpan utuh di `ChatMessage`
/// (satu sumber kebenaran), dan pemisahan ini hanya dipakai di dua
/// tempat: tampilan (`MessageBubble`, think jadi bagian yang bisa
/// dilipat) dan pembangunan prompt riwayat (`ChatViewModel`, think
/// dibuang). Model yang tidak memakai tag think tidak terpengaruh:
/// `split` mengembalikan seluruh isi sebagai jawaban.
public enum ThinkBlock {
    /// Hasil pemisahan satu pesan.
    public struct Parts {
        /// Isi di dalam tag `<think>`, atau nil kalau tidak ada tag.
        public let thinking: String?
        /// Isi di luar tag think (jawaban akhir).
        public let answer: String
        /// True kalau ada `<think>` pembuka tanpa `</think>` penutup —
        /// terjadi saat streaming masih berada di dalam blok berpikir.
        public let isThinkingOpen: Bool
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    /// Pisahkan blok think PERTAMA dari isi. Blok think berikutnya (kalau
    /// ada) dibiarkan di dalam jawaban; model yang dipakai saat ini
    /// hanya mengeluarkan satu blok di awal jawaban.
    public static func split(_ content: String) -> Parts {
        guard let openRange = content.range(of: openTag) else {
            return Parts(thinking: nil, answer: content, isThinkingOpen: false)
        }
        let afterOpen = openRange.upperBound
        if let closeRange = content.range(of: closeTag, range: afterOpen..<content.endIndex) {
            let thinking = String(content[afterOpen..<closeRange.lowerBound])
            let before = String(content[..<openRange.lowerBound])
            let after = String(content[closeRange.upperBound...])
            let answer = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
            return Parts(thinking: thinking, answer: answer, isThinkingOpen: false)
        }
        // Tag dibuka tapi belum ditutup (streaming): semua setelah tag
        // adalah penalaran yang masih berjalan.
        let thinking = String(content[afterOpen...])
        let answer = String(content[..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parts(thinking: thinking, answer: answer, isThinkingOpen: true)
    }

    /// Isi dengan SEMUA blok think dihapus (berulang sampai tidak ada
    /// tag pembuka lagi). Dipakai saat membangun prompt riwayat.
    /// Pesan tanpa tag think dikembalikan apa adanya.
    public static func stripped(_ content: String) -> String {
        var result = content
        while let openRange = result.range(of: openTag) {
            let afterOpen = openRange.upperBound
            if let closeRange = result.range(of: closeTag, range: afterOpen..<result.endIndex) {
                result = String(result[..<openRange.lowerBound]) + String(result[closeRange.upperBound...])
            } else {
                // Blok tak tertutup: buang dari tag pembuka sampai akhir.
                result = String(result[..<openRange.lowerBound])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Preferensi melewati proses berpikir model.
///
/// Qwen3 adalah model hibrida: secara bawaan ia mengeluarkan blok
/// `<think>` panjang sebelum menjawab. Menambahkan `/no_think` di
/// akhir pesan pengguna adalah konvensi resmi Qwen3 untuk meminta
/// model menjawab langsung tanpa blok tersebut — lebih cepat dan
/// menghemat token. Ini preferensi pengguna, bukan instruksi yang
/// mengubah bobot model: model lain (atau Qwen3 yang mengabaikan
/// konvensi ini) tetap boleh mengeluarkan blok think, yang tetap
/// ditampilkan terlipat seperti biasa.
public enum ThinkingPreference {
    public static let skipThinkingDefaultsKey = "llamachat.skipThinking"

    public static var skipThinking: Bool {
        get { UserDefaults.standard.bool(forKey: skipThinkingDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipThinkingDefaultsKey) }
    }
}
