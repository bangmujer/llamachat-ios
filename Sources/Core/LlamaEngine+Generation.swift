import Foundation
import llama

/// Event streaming dari engine ke UI.
///
/// - `.token`: potongan teks yang SUDAH valid UTF-8 (lihat `UTF8StreamDecoder`).
///   Token yang terpotong di tengah karakter multi-byte TIDAK pernah
///   di-emit sebagai `�`; byte-nya ditahan sampai token berikutnya
///   melengkapinya.
/// - `.stats`: kecepatan berjalan, untuk indikator di UI (Fase B).
/// - `.done`: generation berhenti normal / dibatalkan / konteks habis.
///   `.done(.cancelled)` BUKAN error: itu hasil tombol Stop.
/// - `.failed`: error yang harus ditampilkan ke pengguna.
public enum GenerationEvent: Sendable {
    case token(String)
    case stats(tokPerSec: Double)
    case done(DoneReason)
    case failed(AppError)
}

public enum DoneReason: Sendable {
    case endOfTurn
    case maxTokens
    case contextOverflow
    case cancelled
}

extension LlamaEngine {
    /// Mulai generation. Mengembalikan stream; decode berjalan di dalam
    /// actor (bukan main thread) di Task produsen yang dibuat di sini.
    ///
    /// Cancellation: kalau konsumen stream berhenti (mis. `for await`
    /// di-break atau Task konsumen di-cancel), `onTermination` membatalkan
    /// Task produsen. Loop decode juga mengecek `Task.isCancelled` di
    /// tiap iterasi, jadi Stop benar-benar menghentikan decode, bukan
    /// hanya berhenti menampilkan token.
    public func generate(
        prompt: String,
        parameters: SamplingParameters
    ) -> AsyncStream<GenerationEvent> {
        AsyncStream<GenerationEvent> { continuation in
            let producer = Task {
                await self.runGeneration(
                    prompt: prompt,
                    parameters: parameters,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    private func runGeneration(
        prompt: String,
        parameters: SamplingParameters,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) async {
        defer { continuation.finish() }

        let loaded: (model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer)
        do {
            loaded = try requireLoaded()
        } catch let error as AppError {
            continuation.yield(.failed(error))
            return
        } catch {
            continuation.yield(.failed(.generationFailed(error.localizedDescription)))
            return
        }
        let ctx = loaded.context
        let vocab = loaded.vocab

        // Cache dikosongkan setiap generation selesai, apa pun alasannya,
        // supaya generation berikutnya mulai dari state bersih dan harus
        // me-prefill ulang seluruh riwayat (desain multi-turn Fase B).
        defer {
            clearMemory(of: ctx)
        }

        if Task.isCancelled {
            continuation.yield(.done(.cancelled))
            return
        }

        // 1. Tokenize. Selalu lewat llama_tokenize — tidak ada tokenizer manual.
        let promptTokens: [llama_token]
        do {
            promptTokens = try tokenize(prompt, vocab: vocab)
        } catch let error as AppError {
            continuation.yield(.failed(error))
            return
        } catch {
            continuation.yield(.failed(.generationFailed(error.localizedDescription)))
            return
        }
        let nCtx = Int(llama_n_ctx(ctx))
        if promptTokens.isEmpty {
            continuation.yield(.failed(.generationFailed("Prompt kosong setelah tokenisasi.")))
            return
        }
        if promptTokens.count > nCtx {
            continuation.yield(.failed(.contextOverflow(
                "Prompt \(promptTokens.count) token melebihi n_ctx \(nCtx). Pendekkan pesan atau naikkan n_ctx."
            )))
            return
        }
        print("[LlamaEngine] Prefill \(promptTokens.count) token, n_ctx=\(nCtx), maxTokens=\(parameters.maxTokens)")

        // 2. Sampler chain untuk generation ini. Di-free di defer.
        //    JANGAN free sampler individual yang sudah masuk chain.
        let vocabSize = llama_vocab_n_tokens(vocab)
        guard let chain = SamplerFactory.makeChain(parameters: parameters, vocabSize: vocabSize) else {
            continuation.yield(.failed(.generationFailed("Gagal membuat sampler chain.")))
            return
        }
        defer { llama_sampler_free(chain) }

        // 3. Prefill dalam chunk, supaya cancellation bisa menyela di
        //    tengah prompt panjang dan batch tidak melebihi n_batch aktual.
        let batchCapacity = max(1, min(Int(llama_n_batch(ctx)), 512))
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }

        var nPast: Int32 = 0
        var prefillFailed: AppError?
        var chunkStart = 0
        while chunkStart < promptTokens.count {
            if Task.isCancelled {
                continuation.yield(.done(.cancelled))
                return
            }
            let chunkEnd = min(chunkStart + batchCapacity, promptTokens.count)
            let chunk = Array(promptTokens[chunkStart..<chunkEnd])
            let isLastChunk = chunkEnd == promptTokens.count
            fillBatch(&batch, tokens: chunk, startPos: nPast, logitsLastOnly: isLastChunk)
            let rc = llama_decode(ctx, batch)
            if rc != 0 {
                prefillFailed = decodeError(rc, nCtx: nCtx)
                break
            }
            nPast += Int32(chunk.count)
            chunkStart = chunkEnd
        }
        if let prefillFailed {
            continuation.yield(.failed(prefillFailed))
            return
        }

        // 4. Loop decode per token.
        var decoder = UTF8StreamDecoder()
        var generated = 0
        let startedAt = Date()
        var nextTokenToDecode: llama_token?

        while generated < parameters.maxTokens {
            if Task.isCancelled {
                let remainder = decoder.flush()
                if !remainder.isEmpty { continuation.yield(.token(remainder)) }
                continuation.yield(.done(.cancelled))
                return
            }

            // Decode token sebelumnya (nil pada iterasi pertama: logits
            // sudah tersedia dari prefill).
            if let tokenToDecode = nextTokenToDecode {
                fillBatch(&batch, tokens: [tokenToDecode], startPos: nPast, logitsLastOnly: true)
                let rc = llama_decode(ctx, batch)
                if rc != 0 {
                    let remainder = decoder.flush()
                    if !remainder.isEmpty { continuation.yield(.token(remainder)) }
                    if rc == 1 {
                        continuation.yield(.done(.contextOverflow))
                    } else if rc == 2, Task.isCancelled {
                        continuation.yield(.done(.cancelled))
                    } else {
                        continuation.yield(.failed(decodeError(rc, nCtx: nCtx)))
                    }
                    return
                }
                nPast += 1
            }

            // llama_sampler_sample SUDAH memanggil accept di dalamnya
            // (lihat komentar di header llama.h). Jangan panggil
            // llama_sampler_accept lagi — itu akan menghitung token yang
            // sama dua kali untuk repeat penalty.
            let sampled = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, sampled) {
                let remainder = decoder.flush()
                if !remainder.isEmpty { continuation.yield(.token(remainder)) }
                emitFinalStats(continuation: continuation, startedAt: startedAt, generated: generated, ctx: ctx)
                continuation.yield(.done(.endOfTurn))
                return
            }

            generated += 1
            let piece = tokenPiece(sampled, vocab: vocab)
            let text = decoder.append(piece)
            if !text.isEmpty {
                continuation.yield(.token(text))
            }
            if generated % 20 == 0 {
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                continuation.yield(.stats(tokPerSec: Double(generated) / elapsed))
            }
            nextTokenToDecode = sampled
        }

        let remainder = decoder.flush()
        if !remainder.isEmpty { continuation.yield(.token(remainder)) }
        emitFinalStats(continuation: continuation, startedAt: startedAt, generated: generated, ctx: ctx)
        continuation.yield(.done(.maxTokens))
    }

    private func emitFinalStats(
        continuation: AsyncStream<GenerationEvent>.Continuation,
        startedAt: Date,
        generated: Int,
        ctx: OpaquePointer
    ) {
        let perf = llama_perf_context(ctx)
        if perf.n_eval > 0, perf.t_eval_ms > 0 {
            let tokPerSec = Double(perf.n_eval) / (perf.t_eval_ms / 1000.0)
            continuation.yield(.stats(tokPerSec: tokPerSec))
            print("[LlamaEngine] Perf: prompt \(perf.n_p_eval) token dalam \(perf.t_p_eval_ms) ms, generate \(perf.n_eval) token dalam \(perf.t_eval_ms) ms (\(tokPerSec) tok/detik)")
        } else {
            let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
            continuation.yield(.stats(tokPerSec: Double(generated) / elapsed))
        }
    }

    private func decodeError(_ rc: Int32, nCtx: Int) -> AppError {
        switch rc {
        case 1:
            return .contextOverflow("Tidak ada slot KV untuk batch berikutnya (n_ctx \(nCtx)). Generation dihentikan, bukan di-truncate diam-diam.")
        case 2:
            return .cancelled
        default:
            return .generationFailed("llama_decode mengembalikan kode \(rc).")
        }
    }

    // MARK: - Batch

    /// Isi batch yang dialokasikan `llama_batch_init`.
    ///
    /// VERIFY AGAINST GENERATED INTERFACE: pengisian lewat subscript
    /// (`batch.token[i]`, `batch.pos[i]`, `batch.seq_id[i][0]`) adalah
    /// pola dari contoh Swift llama.cpp; kalau impor C di toolchain CI
    /// mengekspos field-field ini dengan spelling berbeda, error compile
    /// di baris ini yang akan menunjukkannya — jangan ubah logika decode
    /// sebelum membaca error tersebut.
    private func fillBatch(
        _ batch: inout llama_batch,
        tokens: [llama_token],
        startPos: Int32,
        logitsLastOnly: Bool
    ) {
        batch.n_tokens = Int32(tokens.count)
        for index in tokens.indices {
            batch.token[index] = tokens[index]
            batch.pos[index] = startPos + Int32(index)
            batch.n_seq_id[index] = 1
            batch.seq_id[index][0] = 0
            let isLast = index == tokens.count - 1
            batch.logits[index] = (logitsLastOnly && isLast) ? 1 : 0
        }
    }

    // MARK: - Tokenize / detokenize

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        // add_special = true: BOS/EOS ditambah HANYA kalau vocab model
        // memang mengonfigurasikannya (header llama_tokenize).
        // parse_special = true: penanda template (<|im_start|>, dst.)
        // di prompt hasil render dikenali sebagai special token, bukan
        // teks biasa. Jangan tokenize teks mentah pengguna sendirian
        // dengan parse_special=true di Fase B.
        var capacity = max(32, text.utf8.count + 16)
        while true {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let result = tokens.withUnsafeMutableBufferPointer { tokenBuffer in
                text.withCString { cText in
                    llama_tokenize(
                        vocab,
                        cText,
                        Int32(text.utf8.count),
                        tokenBuffer.baseAddress,
                        Int32(capacity),
                        true,
                        true
                    )
                }
            }
            if result >= 0 {
                return Array(tokens.prefix(Int(result)))
            }
            if result == Int32.min {
                throw AppError.generationFailed("Hasil tokenisasi melampaui batas int32.")
            }
            // result negatif = jumlah token yang dibutuhkan.
            let needed = Int(-result)
            if needed <= capacity {
                throw AppError.generationFailed("Tokenisasi gagal dengan kode \(result).")
            }
            capacity = needed
        }
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        // 256 byte jauh di atas piece terpanjang yang wajar; kalau suatu
        // saat ada piece lebih panjang, token itu di-skip daripada crash.
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer { buf in
            llama_token_to_piece(vocab, token, buf.baseAddress, Int32(buf.count), 0, false)
        }
        guard length > 0 else { return [] }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }
}

/// Decoder UTF-8 incremental.
///
/// Byte dari tiap token diakumulasi. Hanya prefix yang membentuk UTF-8
/// valid yang di-emit; suffix yang bisa jadi awal karakter multi-byte
/// yang belum lengkap ditahan sampai token berikutnya. Ini mencegah
/// karakter `�` muncul di tengah streaming — bug paling umum di wrapper
/// llama.cpp.
///
/// Byte yang benar-benar tidak valid (tidak mungkin dari tokenizer yang
/// valid) hanya akan keluar lewat `flush()` di akhir generation, dengan
/// decoding lossy, supaya tidak ada byte yang hilang diam-diam.
private struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let validCount = validPrefixLength(pending)
        guard validCount > 0 else { return "" }
        let prefix = Array(pending.prefix(validCount))
        pending.removeFirst(validCount)
        return String(decoding: prefix, as: UTF8.self)
    }

    mutating func flush() -> String {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return "" }
        return String(decoding: pending, as: UTF8.self)
    }

    private func validPrefixLength(_ bytes: [UInt8]) -> Int {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let needed: Int
            if byte < 0x80 {
                needed = 0
            } else if byte >= 0xC2, byte <= 0xDF {
                needed = 1
            } else if byte >= 0xE0, byte <= 0xEF {
                needed = 2
            } else if byte >= 0xF0, byte <= 0xF4 {
                needed = 3
            } else {
                // Byte awal tidak valid: berhenti sebelum byte ini.
                break
            }
            if index + needed >= bytes.count {
                // Urutan belum lengkap: tahan dari byte awal ini.
                break
            }
            var valid = true
            if needed > 0 {
                for offset in 1...needed {
                    let continuation = bytes[index + offset]
                    if continuation < 0x80 || continuation > 0xBF {
                        valid = false
                        break
                    }
                }
            }
            if !valid { break }
            index += needed + 1
        }
        return index
    }
}
