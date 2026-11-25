import Foundation
import Darwin
import llama

/// Error yang bisa ditampilkan langsung ke pengguna (Bahasa Indonesia).
///
/// Tidak ada force unwrap di jalur runtime engine; setiap kegagalan C API
/// yang mengembalikan nil / kode error dipetakan ke salah satu kasus ini.
public enum AppError: Error, LocalizedError, Equatable, Sendable {
    case modelNotFound(String)
    case outOfMemory(String)
    case modelCorrupted(String)
    case contextOverflow(String)
    case cancelled
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let detail):
            return "Model tidak ditemukan. \(detail)"
        case .outOfMemory(let detail):
            return "Memori tidak cukup untuk memuat model. \(detail)"
        case .modelCorrupted(let detail):
            return "File model rusak atau tidak didukung. \(detail)"
        case .contextOverflow(let detail):
            return "Konteks penuh. \(detail)"
        case .cancelled:
            return "Dibatalkan."
        case .generationFailed(let detail):
            return "Gagal menghasilkan teks. \(detail)"
        }
    }
}

/// Estimasi memori sebelum load penuh. Semua angka dalam byte.
public struct MemoryEstimate: Sendable {
    public let fileBytes: Int64
    public let kvBytes: Int64
    public let overheadBytes: Int64
    public let totalBytes: Int64
    public let availableBytes: UInt64
    public let safeLimitBytes: Int64
    public let nCtx: Int32

    public var isOverAvailable: Bool { totalBytes > Int64(availableBytes) }
    public var isOverSafeLimit: Bool { totalBytes > safeLimitBytes }
}

/// Actor inference. SATU-SATUNYA tempat pointer C llama.cpp hidup.
///
/// - `llama_model *`, `llama_context *`, dan vocab (`llama_vocab *`) adalah
///   tipe opaque di `llama.h`, sehingga di Swift terlihat sebagai
///   `OpaquePointer`. Pointer-pointer ini TIDAK PERNAH keluar dari actor:
///   tidak disimpan di ViewModel, tidak dikirim ke View, tidak di-return.
/// - Semua C API dipanggil dari method actor (bukan MainActor), sehingga
///   inference tidak pernah jalan di main thread. Pemanggil memakai
///   `await`, yang memindahkan eksekusi ke executor actor.
/// - Pembebasan pointer, eksplisit:
///   * `llama_model_free` — di `unload()` dan di `deinit`.
///   * `llama_free` (context) — di `unload()` dan di `deinit`.
///   * `llama_sampler_free` (chain) — di `defer` tiap generation, di
///     `LlamaEngine+Generation.swift`. BUKAN di sini.
///   * `llama_batch_free` — di `defer` tiap generation, di file yang sama.
///   * `llama_backend_free` — di `unload()` / `deinit`, dijaga flag
///     `backendInitialized` supaya tidak dipanggil dua kali.
/// - Asumsi instance tunggal: `llama_backend_init/free` bersifat global.
///   Jangan buat dua `LlamaEngine` hidup bersamaan di Fase A.
public actor LlamaEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var backendInitialized = false

    /// Descriptor model yang sedang ter-load, kalau ada.
    public private(set) var loadedDescriptor: ModelDescriptor?

    /// n_ctx AKTUAL dari context (bisa berbeda dari yang diminta; header
    /// menyarankan selalu menanyakan nilai aktual setelah init).
    public private(set) var actualNCtx: Int32 = 0

    public var isLoaded: Bool {
        model != nil && context != nil
    }

    public init() {}

    deinit {
        // deinit actor berjalan sinkron tanpa await; akses state di sini
        // diizinkan dan tidak boleh memanggil method actor lain.
        if let ctx = context {
            llama_free(ctx)
        }
        if let mdl = model {
            llama_model_free(mdl)
        }
        if backendInitialized {
            llama_backend_free()
        }
    }

    // MARK: - Load

    /// Muat model GGUF pertama di Models/ dengan parameter default device.
    public func loadFirstModel(parameters: SamplingParameters) async throws -> ModelDescriptor {
        let url = try ModelLoader.firstModel()
        return try await loadModel(at: url, nCtx: parameters.nCtx)
    }

    /// Muat satu file GGUF. Alurnya: validasi magic -> probe vocab-only
    /// untuk metadata -> estimasi memori -> tolak kalau tidak cukup ->
    /// load penuh -> buat context.
    public func loadModel(at url: URL, nCtx requestedNCtx: Int) async throws -> ModelDescriptor {
        if Task.isCancelled { throw AppError.cancelled }

        try ModelLoader.validateGGUFMagic(at: url)
        let fileSize = try ModelLoader.fileSizeBytes(at: url)

        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }

        // 1. Probe metadata tanpa bobot (vocab_only). Cepat, dan memberi
        //    n_layer / n_head_kv / n_ctx_train yang dibutuhkan estimasi.
        let probe = try probeMetadata(at: url)
        var descriptor = ModelDescriptor(fileURL: url, fileSizeBytes: fileSize)
        descriptor.nParams = probe.nParams
        descriptor.nLayer = probe.nLayer
        descriptor.nEmbd = probe.nEmbd
        descriptor.nHead = probe.nHead
        descriptor.nHeadKV = probe.nHeadKV
        descriptor.nCtxTrain = probe.nCtxTrain
        descriptor.chatTemplate = probe.chatTemplate

        // 2. n_ctx efektif: jangan melebihi context latih model.
        var effectiveNCtx = Int32(requestedNCtx)
        if probe.nCtxTrain > 0, effectiveNCtx > probe.nCtxTrain {
            print("[LlamaEngine] n_ctx diminta \(effectiveNCtx) melebihi n_ctx_train \(probe.nCtxTrain); dipakai \(probe.nCtxTrain).")
            effectiveNCtx = probe.nCtxTrain
        }
        if effectiveNCtx <= 0 { effectiveNCtx = 2048 }

        // 3. Estimasi + guard SEBELUM load penuh.
        let estimate = estimateMemory(
            fileBytes: fileSize,
            nCtx: effectiveNCtx,
            nLayer: probe.nLayer,
            nEmbd: probe.nEmbd,
            nHead: probe.nHead,
            nHeadKV: probe.nHeadKV
        )
        print("[LlamaEngine] Estimasi memori: file=\(estimate.fileBytes) KV=\(estimate.kvBytes) overhead=\(estimate.overheadBytes) total=\(estimate.totalBytes) tersedia=\(estimate.availableBytes) batasAman=\(estimate.safeLimitBytes) n_ctx=\(estimate.nCtx)")
        if estimate.isOverAvailable || estimate.isOverSafeLimit {
            throw AppError.outOfMemory(
                "Estimasi \(ByteCountFormatter.string(fromByteCount: estimate.totalBytes, countStyle: .file)) melebihi memori tersedia \(ByteCountFormatter.string(fromByteCount: Int64(estimate.availableBytes), countStyle: .file)) / batas aman \(ByteCountFormatter.string(fromByteCount: estimate.safeLimitBytes, countStyle: .file)). Coba n_ctx lebih kecil atau model dengan kuantisasi lebih ringan."
            )
        }
        if Task.isCancelled { throw AppError.cancelled }

        // 4. Load penuh. Model lama (kalau ada) di-unload dulu.
        unload()
        if !backendInitialized {
            llama_backend_init()
            backendInitialized = true
        }

        var modelParams = llama_model_default_params()
        // Brief: full offload GPU. Header v1.0.0: nilai negatif berarti
        // semua layer; 99 > jumlah layer model 3B/4B sehingga efeknya
        // sama (semua layer), dan nilai yang dipakai tetap yang diminta
        // brief supaya mudah diaudit di log. Jangan ubah diam-diam.
        modelParams.n_gpu_layers = 99
        // VERIFY AGAINST HEADER: field lain dibiarkan apa adanya dari
        // llama_model_default_params() (load_mode, mmap, dsb.). Jangan
        // menebak default-nya di sini; nilai aktual tidak di-log oleh
        // llama.cpp v1.0.0 lewat API publik ini.
        let loadedModel: OpaquePointer? = url.path.withCString { cPath in
            llama_model_load_from_file(cPath, modelParams)
        }
        guard let loadedModel else {
            throw AppError.modelCorrupted("llama_model_load_from_file mengembalikan nil untuk \(url.lastPathComponent). File mungkin terpotong atau arsitekturnya belum didukung v1.0.0.")
        }
        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = UInt32(effectiveNCtx)
        // VERIFY AGAINST HEADER: n_batch / n_ubatch / n_threads dibiarkan
        // default dari llama_context_default_params(). Nilai aktual
        // dibaca kembali lewat llama_n_batch() dan di-log di bawah, dan
        // prefill di-chunk mengikuti nilai aktual itu, bukan asumsi.
        ctxParams.embeddings = false
        ctxParams.offload_kqv = true

        guard let ctx = llama_init_from_model(loadedModel, ctxParams) else {
            llama_model_free(loadedModel)
            self.model = nil
            self.vocab = nil
            throw AppError.modelCorrupted("llama_init_from_model gagal. Coba n_ctx lebih kecil.")
        }
        self.context = ctx
        self.actualNCtx = Int32(llama_n_ctx(ctx))
        self.loadedDescriptor = descriptor

        let desc = modelDescription(of: loadedModel)
        print("[LlamaEngine] Model ter-load: \(desc) n_ctx aktual=\(actualNCtx) n_batch aktual=\(llama_n_batch(ctx)) file=\(url.lastPathComponent)")
        if let template = descriptor.chatTemplate, !template.isEmpty {
            print("[LlamaEngine] Template chat bawaan model (500 karakter pertama):\n\(String(template.prefix(500)))")
        } else {
            print("[LlamaEngine] Model tidak membawa chat template; fallback manual akan dipakai.")
        }
        return descriptor
    }

    /// Bebaskan context + model. Aman dipanggil berulang. Setelah unload,
    /// `isLoaded` false dan generation berikutnya harus load ulang.
    public func unload() {
        if let ctx = context {
            clearMemory(of: ctx)
            llama_free(ctx)
        }
        if let mdl = model {
            llama_model_free(mdl)
        }
        context = nil
        model = nil
        vocab = nil
        loadedDescriptor = nil
        actualNCtx = 0
        if backendInitialized {
            llama_backend_free()
            backendInitialized = false
        }
    }

    /// Hentikan generation yang sedang berjalan dari sisi luar actor dan
    /// kosongkan KV cache, tanpa men-free model/context. Dipanggil saat
    /// memory warning. Generation yang sedang jalan tetap harus berhenti
    /// lewat cancellation Task-nya (cek `Task.isCancelled` di loop);
    /// method ini hanya membersihkan state supaya generation berikutnya
    /// mulai dari cache kosong.
    public func handleMemoryWarning() {
        guard let ctx = context else { return }
        clearMemory(of: ctx)
        print("[LlamaEngine] Memory warning: KV cache dikosongkan.")
    }

    /// Kosongkan KV cache kalau context punya memory. `llama_get_memory`
    /// bisa mengembalikan nil untuk context tanpa memory; jangan panggil
    /// `llama_memory_clear` dengan nil.
    func clearMemory(of ctx: OpaquePointer) {
        let memory = llama_get_memory(ctx)
        guard memory != nil else { return }
        llama_memory_clear(memory, true)
    }

    // MARK: - Metadata probe

    private struct ProbeResult {
        let nParams: UInt64
        let nLayer: Int32
        let nEmbd: Int32
        let nHead: Int32
        let nHeadKV: Int32
        let nCtxTrain: Int32
        let chatTemplate: String?
    }

    private func probeMetadata(at url: URL) throws -> ProbeResult {
        var params = llama_model_default_params()
        params.vocab_only = true
        params.n_gpu_layers = 0
        let probeModel: OpaquePointer? = url.path.withCString { cPath in
            llama_model_load_from_file(cPath, params)
        }
        guard let probeModel else {
            throw AppError.modelCorrupted("Gagal membaca metadata GGUF (probe vocab-only): \(url.lastPathComponent)")
        }
        defer { llama_model_free(probeModel) }

        let templatePtr = llama_model_chat_template(probeModel, nil)
        let template: String? = templatePtr.map { String(cString: $0) }
        return ProbeResult(
            nParams: llama_model_n_params(probeModel),
            nLayer: llama_model_n_layer(probeModel),
            nEmbd: llama_model_n_embd(probeModel),
            nHead: llama_model_n_head(probeModel),
            nHeadKV: llama_model_n_head_kv(probeModel),
            nCtxTrain: llama_model_n_ctx_train(probeModel),
            chatTemplate: template.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func modelDescription(of model: OpaquePointer) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = buffer.withUnsafeMutableBufferPointer { buf in
            llama_model_desc(model, buf.baseAddress, buf.count)
        }
        guard length > 0 else { return "(deskripsi tidak tersedia)" }
        return String(cString: buffer)
    }

    // MARK: - Estimasi memori

    /// KV cache dihitung dari metadata runtime, BUKAN angka hardcode
    /// per model: n_ctx * n_layer * n_head_kv * head_dim * 2 (K+V) * 2 byte (f16).
    /// head_dim = n_embd / n_head. Ini lebih akurat daripada rumus
    /// singkat di brief (n_ctx * n_layer * 2 * sizeof(f16) * 2) yang
    /// tidak memperhitungkan head_dim dan KV heads (GQA). Kalau metadata
    /// tidak memberi head_dim, dipakai rumus singkat brief sebagai fallback
    /// dan estimasi ditandai perkiraan lewat nilai yang lebih kecil.
    /// KV bertipe f16 diasumsikan sebagai batas atas yang konservatif;
    /// kalau type_k/type_v aktual lebih kecil (mis. FP8 di v1.0.0),
    /// pemakaian nyata bisa lebih rendah dari estimasi.
    func estimateMemory(
        fileBytes: Int64,
        nCtx: Int32,
        nLayer: Int32,
        nEmbd: Int32,
        nHead: Int32,
        nHeadKV: Int32
    ) -> MemoryEstimate {
        let overhead: Int64 = 300 * 1024 * 1024
        let kvBytes: Int64
        if nHead > 0, nHeadKV > 0, nEmbd > 0 {
            let headDim = Int64(nEmbd / nHead)
            kvBytes = Int64(nCtx) * Int64(nLayer) * Int64(nHeadKV) * headDim * 2 * 2
        } else {
            kvBytes = Int64(nCtx) * Int64(nLayer) * 2 * 2 * 2
        }
        let total = fileBytes + kvBytes + overhead
        let available = availableMemoryBytes()
        let physical = ProcessInfo.processInfo.physicalMemory
        let safeLimit: Int64
        if physical <= 6 * 1024 * 1024 * 1024 {
            // Dilonggarkan atas persetujuan pengguna (23:26 WIT,
            // 2026-11-25) untuk Qwen3-4B Q4_K_M: file 2.497 GB, estimasi
            // ~3.1 GB di n_ctx 2048 dan ~3.4 GB di n_ctx 4096. Batas
            // 2.6 GB lama akan selalu menolak model ini. Cek memori
            // tersedia (`os_proc_available_memory`) TETAP berlaku sebagai
            // penolakan kedua, dan tidak ada janji bebas jetsam: kalau
            // RAM mepet saat load, iOS tetap bisa mematikan app. Tes di
            // device yang membuktikan, bukan angka ini.
            safeLimit = 3_800_000_000
        } else if physical <= 8 * 1024 * 1024 * 1024 {
            safeLimit = 3_500_000_000
        } else {
            safeLimit = 3_500_000_000
        }
        return MemoryEstimate(
            fileBytes: fileBytes,
            kvBytes: kvBytes,
            overheadBytes: overhead,
            totalBytes: total,
            availableBytes: available,
            safeLimitBytes: safeLimit,
            nCtx: nCtx
        )
    }

    func availableMemoryBytes() -> UInt64 {
        let available = UInt64(os_proc_available_memory())
        if available > 0 {
            return available
        }
        // Fallback kalau API tidak memberi angka: setengah RAM fisik.
        return ProcessInfo.processInfo.physicalMemory / 2
    }

    // MARK: - Akses internal untuk generation (satu file yang sama)

    /// Dipakai HANYA oleh `LlamaEngine+Generation.swift`.
    func requireLoaded() throws -> (model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer) {
        guard let model, let context, let vocab else {
            throw AppError.modelNotFound("Belum ada model yang ter-load. Muat model dulu.")
        }
        return (model, context, vocab)
    }
}
