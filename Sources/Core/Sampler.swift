import Foundation
import llama

/// Parameter sampling untuk satu generation.
///
/// Nilai-nilai ini disimpan per-model mulai Fase C. Di Fase A hanya ada
/// satu set default yang dipakai smoke test; tidak ada UI untuk mengubahnya.
public struct SamplingParameters: Equatable, Codable, Sendable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int32
    public var repeatPenalty: Float
    /// Token terakhir yang dikenai repeat penalty. Bukan bagian dari brief,
    /// tapi `llama_sampler_init_penalties` WAJIB menerima nilai ini, jadi
    /// diekspos di sini dengan default 64 (nilai umum di llama.cpp).
    public var penaltyLastN: Int32
    public var maxTokens: Int
    public var nCtx: Int

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        topK: Int32 = 40,
        repeatPenalty: Float = 1.1,
        penaltyLastN: Int32 = 64,
        // Default 1024 (sebelumnya 256): jawaban Qwen3 terpotong di
        // tengah kalimat pada 256 karena blok <think> ikut memakan
        // budget token. Pengguna tetap bisa mengubah per-model di
        // Settings; batas kerasnya tetap n_ctx, dan tombol Stop selalu
        // tersedia kalau jawaban dirasa kepanjangan.
        maxTokens: Int = 1024,
        nCtx: Int = 2048
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.penaltyLastN = penaltyLastN
        self.maxTokens = maxTokens
        self.nCtx = nCtx
    }

    /// Default untuk device RAM <= 6 GB (termasuk iPhone 15, 6 GB).
    /// Brief menulis default 4096 dan 2048 hanya untuk "< 6 GB"; iPhone 15
    /// tepat 6 GB diperlakukan sebagai kelas 6 GB di sini supaya KV cache
    /// tidak memakan headroom yang dibutuhkan bobot model. Pengguna tetap
    /// bisa menaikkan n_ctx per-model di Fase C, dengan guard memori yang
    /// akan menolak kalau estimasinya melebihi memori tersedia.
    public static func defaultForCurrentDevice() -> SamplingParameters {
        let physical = ProcessInfo.processInfo.physicalMemory
        // 6 GiB = 6 * 1024^3. Batas inklusif: <= 6 GiB -> 2048.
        if physical <= 6 * 1024 * 1024 * 1024 {
            return SamplingParameters(nCtx: 2048)
        }
        return SamplingParameters(nCtx: 4096)
    }
}

/// Pembangun sampler chain llama.cpp.
///
/// VERIFIKASI HEADER (llama.cpp v1.0.0, `include/llama.h`, bagian
/// "Sampling API", baris 2447-3013): TIDAK ADA file `llama-sampling.h`
/// terpisah di v1.0.0 — semua fungsi sampler hidup di `llama.h`.
/// Fungsi yang dipakai di sini dan sudah dicek di header tersebut:
/// `llama_sampler_chain_default_params`, `llama_sampler_chain_init`,
/// `llama_sampler_chain_add`, `llama_sampler_free`,
/// `llama_sampler_init_penalties`, `llama_sampler_init_top_k`,
/// `llama_sampler_init_top_p`, `llama_sampler_init_temp`,
/// `llama_sampler_init_dist`, `llama_sampler_init_greedy`,
/// `llama_sampler_sample`.
///
/// ATURAN KEPEMILIKAN (header, baris 2645-2660): sampler yang sudah
/// ditambahkan ke chain dengan `llama_sampler_chain_add` dimiliki oleh
/// chain dan TIDAK BOLEH di-free sendiri; chain di-free dengan satu
/// `llama_sampler_free` di `defer` pemanggil. Fungsi ini mengembalikan
/// chain yang BELUM di-free; pemanggil wajib men-free-nya.
///
/// Fungsi ini HANYA boleh dipanggil dari dalam `LlamaEngine` (actor),
/// karena ia memanggil C API yang state-nya hidup di actor. Tidak ada
/// sampler pointer yang disimpan di luar actor.
enum SamplerFactory {
    static func makeChain(
        parameters: SamplingParameters,
        vocabSize: Int32
    ) -> UnsafeMutablePointer<llama_sampler>? {
        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else {
            return nil
        }

        // Urutan chain mengikuti urutan umum llama.cpp: penalties dulu,
        // lalu pemangkasan (top_k/top_p), lalu temperature, lalu sampler
        // penentu token (dist/greedy) PALING AKHIR.
        if parameters.repeatPenalty != 1.0, parameters.penaltyLastN > 0 {
            let penalties = llama_sampler_init_penalties(
                vocabSize,
                parameters.penaltyLastN,
                parameters.repeatPenalty,
                0.0,
                0.0
            )
            llama_sampler_chain_add(chain, penalties)
        }

        if parameters.topK > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(parameters.topK))
        }

        if parameters.topP < 1.0 {
            // min_keep = 1, sama seperti contoh di header llama.h.
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(parameters.topP, 1))
        }

        if parameters.temperature <= 0 {
            // temperature 0 = greedy deterministik. Jangan tambahkan dist.
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(parameters.temperature))
            // LLAMA_DEFAULT_SEED = 0xFFFFFFFF berarti "seed acak" (header).
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(0xFFFF_FFFF)))
        }

        return chain
    }
}
