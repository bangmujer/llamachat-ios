import Foundation
import SwiftData
import SwiftUI

/// ViewModel chat Fase B/D.
///
/// Tanggung jawabnya hanya tiga: memegang riwayat pesan di memori,
/// menjalankan load + generation lewat `LlamaEngine`, dan menerjemahkan
/// event stream menjadi state UI. Tidak ada pointer C di sini; tidak ada
/// network call.
///
/// Fase D menambahkan persistensi: riwayat juga disimpan ke SwiftData
/// (`Conversation` / `StoredMessage`) lewat `modelContext` yang
/// disuntikkan dari App. `messages` di memori tetap menjadi sumber
/// kebenaran selama chat berjalan; penyimpanan terjadi pada
/// titik-titik diskrit (pesan pengguna terkirim, generation selesai /
/// dibatalkan, ganti percakapan) — BUKAN per flush token (20 fps),
/// supaya write database tidak membebani streaming.
///
/// Multi-turn: `LlamaEngine` mengosongkan KV cache setiap generation
/// selesai (desain Fase A), jadi setiap giliran me-render SELURUH
/// riwayat menjadi satu prompt dan me-prefill ulang dari awal. Itu
/// lambat untuk riwayat sangat panjang, tapi benar dan sederhana;
/// optimasi KV reuse adalah pekerjaan setelah Fase D, bukan di sini.
///
/// Throttle UI: token dari engine dibuffer dan di-flush ke pesan
/// maksimal tiap 50 ms (~20 fps, sesuai brief), supaya ScrollView tidak
/// me-render ulang per token.
/// Permintaan tool yang menunggu konfirmasi pengguna (Fase 2 + Agent).
/// Non-nil = dialog konfirmasi sedang tampil di `ChatView`. Dipakai
/// sebagai `item` untuk `.alert(item:)` di View, jadi harus
/// `Identifiable`.
public struct PendingToolCall: Identifiable, Equatable {
    public let id = UUID()
    public let request: ToolCallRequest

    public var title: String { "Jalankan tool?" }
    public var message: String { request.summary }
}

@MainActor
public final class ChatViewModel: ObservableObject {
    private static let systemPromptDefaultsKey = "llamachat.systemPrompt"
    /// Default minimal dan netral: hanya bahasa jawaban. TIDAK ada
    /// arahan isi, gaya, atau batasan apa pun di sini — app tidak
    /// menyaring atau mengarahkan jawaban model. Pengguna bebas
    /// menulis system prompt apa pun (termasuk mengosongkannya) lewat
    /// editor di Settings; isi prompt sepenuhnya tanggung jawab
    /// pengguna. Penolakan yang berasal dari bobot model itu sendiri
    /// tidak bisa dihapus dari sisi app.
    private static let defaultSystemPrompt =
        "Kamu adalah asisten AI. Jawablah dalam Bahasa Indonesia."

    private let engine: LlamaEngine
    /// Context SwiftData (mainContext dari App). Semua akses entity
    /// terjadi di MainActor, sesuai konteks ini.
    private let modelContext: ModelContext

    /// ID percakapan yang sedang dibuka di database, kalau percakapan
    /// ini sudah pernah disimpan. Nil = percakapan baru yang belum
    /// pernah disimpan (disimpan saat pesan pertama terkirim).
    public private(set) var currentConversationID: UUID?
    private var hasRestoredLatest = false

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var conversationTitle = "Percakapan baru"
    @Published public private(set) var isLoadingModel = false
    @Published public private(set) var isGenerating = false
    @Published public private(set) var isModelLoaded = false
    @Published public private(set) var modelName: String?
    @Published public private(set) var actualNCtx: Int32 = 0
    /// Descriptor model yang sedang ter-load, lengkap dengan metadata
    /// runtime (termasuk chat template mentah untuk auto-detect).
    @Published public private(set) var loadedDescriptor: ModelDescriptor?
    /// Parameter sampling aktif. Diubah lewat `applyParameters` (Fase C)
    /// dan disimpan per-model; dibaca dari simpanan saat model di-load.
    @Published public private(set) var parameters: SamplingParameters
    /// Pilihan template pengguna (`.auto` = deteksi dari metadata).
    @Published public private(set) var templateKind: ChatTemplateKind = .auto
    @Published public private(set) var tokPerSec: Double?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusText: String = "Belum ada model."
    /// Bertambah tiap flush token dan tiap pesan baru; dipakai View
    /// sebagai anchor untuk auto-scroll, supaya scroll tidak bergantung
    /// pada perbandingan string isi pesan.
    @Published public private(set) var scrollVersion = 0

    /// Token konteks dari generation terakhir (Fase 2): jumlah token
    /// prompt, token yang dihasilkan, dan batas n_ctx. Nil = belum ada
    /// generation sejak app dibuka. Dipakai bar konteks di `ChatView`.
    @Published public private(set) var contextPromptTokens: Int?
    @Published public private(set) var contextGeneratedTokens: Int?
    @Published public private(set) var contextLimit: Int = 0

    /// Permintaan tool yang menunggu konfirmasi pengguna (Fase 2 +
    /// Agent). Nil kalau tidak ada dialog konfirmasi yang tampil.
    @Published public private(set) var pendingToolCall: PendingToolCall?

    /// System prompt yang dipakai generation BERIKUTNYA. Disimpan di
    /// UserDefaults dan langsung berlaku untuk pesan berikutnya setelah
    /// diubah — tidak perlu restart, tidak perlu load ulang model.
    @Published public private(set) var systemPrompt: String

    private var generationTask: Task<Void, Never>?
    private var hasAttemptedLoad = false

    /// Pelaksana tool agent. Satu instance per ViewModel; tidak ada
    /// state antar pemanggilan yang perlu dijaga.
    private let toolExecutor = ToolExecutor()
    /// Continuation yang menunggu jawaban dialog konfirmasi tool.
    /// WAJIB di-resume tepat sekali — `resolvePendingToolCall` dan
    /// `stop()` adalah satu-satunya tempat yang me-resume-nya.
    private var pendingToolContinuation: CheckedContinuation<Bool, Never>?

    public init(engine: LlamaEngine, modelContext: ModelContext) {
        self.engine = engine
        self.modelContext = modelContext
        self.parameters = SamplingParameters.defaultForCurrentDevice()
        let saved = UserDefaults.standard.string(forKey: Self.systemPromptDefaultsKey)
        if let saved {
            // String kosong yang tersimpan berarti pengguna sengaja
            // mengosongkan system prompt (Fase 2: editor mengizinkan
            // kosong) — jangan ganti dengan default.
            self.systemPrompt = saved
        } else {
            self.systemPrompt = Self.defaultSystemPrompt
        }
    }

    public var canSend: Bool {
        isModelLoaded && !isGenerating && !isLoadingModel
    }

    // MARK: - System prompt

    public func setSystemPrompt(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        systemPrompt = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.systemPromptDefaultsKey)
    }

    // MARK: - Model

    /// Coba load model pertama di Models/. `modelNotFound` saat pertama
    /// kali bukan error yang ditampilkan sebagai banner — itu state
    /// kosong normal (pengguna belum mengimpor model).
    public func loadModelIfNeeded() async {
        guard !hasAttemptedLoad else { return }
        hasAttemptedLoad = true
        await loadModel()
    }

    public func loadModel() async {
        guard !isLoadingModel, generationTask == nil else { return }
        isLoadingModel = true
        errorMessage = nil
        statusText = "Memuat model…"
        defer { isLoadingModel = false }
        do {
            // Pengaturan tersimpan dibaca DULU dari nama file model
            // pertama, supaya n_ctx tersimpan yang dipakai saat load
            // (bukan default lalu load ulang).
            let firstURL = try ModelLoader.firstModel()
            let stored = ModelSettingsStore.load(for: firstURL.lastPathComponent)
            let effectiveParameters = stored?.parameters ?? parameters
            let descriptor = try await engine.loadModel(at: firstURL, nCtx: effectiveParameters.nCtx)
            let nCtx = await engine.actualNCtx
            parameters = effectiveParameters
            templateKind = stored?.template ?? .auto
            loadedDescriptor = descriptor
            modelName = descriptor.fileName
            actualNCtx = nCtx
            isModelLoaded = true
            statusText = "Model siap: \(descriptor.fileName) (\(descriptor.displaySize)), n_ctx \(nCtx)."
        } catch let error as AppError {
            isModelLoaded = false
            loadedDescriptor = nil
            statusText = error.errorDescription ?? error.localizedDescription
            // Hanya tampilkan sebagai banner kalau bukan sekadar
            // "belum ada model" — state kosong sudah menjelaskan itu.
            if case .modelNotFound = error {
                errorMessage = nil
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            isModelLoaded = false
            loadedDescriptor = nil
            statusText = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    /// Unload model dari engine. Dipakai Model Manager sebelum menghapus
    /// file model yang sedang ter-load, dan saat pengguna mengganti
    /// n_ctx lewat Settings (load ulang sesudahnya).
    public func unloadModel() async {
        stop()
        await engine.unload()
        isModelLoaded = false
        loadedDescriptor = nil
        modelName = nil
        actualNCtx = 0
        statusText = "Model di-unload."
    }

    /// Terapkan parameter + template baru untuk model yang sedang
    /// ter-load, dan simpan per-model. Perubahan parameter selain n_ctx
    /// berlaku untuk generation berikutnya tanpa load ulang; perubahan
    /// n_ctx memicu unload + load ulang dengan n_ctx baru.
    public func applyParameters(_ newParameters: SamplingParameters, templateKind newTemplateKind: ChatTemplateKind) async {
        let oldNCtx = parameters.nCtx
        parameters = newParameters
        templateKind = newTemplateKind
        if let name = modelName {
            ModelSettingsStore.save(for: name, parameters: newParameters, template: newTemplateKind)
        }
        guard newParameters.nCtx != oldNCtx, isModelLoaded else { return }
        await unloadModel()
        hasAttemptedLoad = false
        await loadModelIfNeeded()
    }

    /// Salin file .gguf pilihan pengguna ke Models/, lalu load.
    /// Tetap ada di empty state ChatView dan di Model Manager sampai
    /// download URL (Fase C) teruji; logika salinnya sama dengan
    /// harness Fase A.
    public func importPickedModel(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let picked = urls.first else { return }
            Task {
                do {
                    let dir = try ModelLoader.modelsDirectory()
                    let destination = dir.appendingPathComponent(picked.lastPathComponent)
                    let accessing = picked.startAccessingSecurityScopedResource()
                    defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: picked, to: destination)
                    // Tolak sejak di sini kalau file yang dipilih bukan
                    // GGUF (mis. karena picker mengizinkan .data): file
                    // dihapus lagi supaya tidak mengotori daftar model
                    // dengan file yang pasti gagal saat load.
                    try ModelLoader.validateGGUFMagic(at: destination)
                    let size = try ModelLoader.fileSizeBytes(at: destination)
                    statusText = "Model tersalin: \(destination.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). Memuat…"
                    hasAttemptedLoad = false
                    await loadModelIfNeeded()
                } catch {
                    statusText = "Gagal menyalin model: \(error.localizedDescription)"
                    errorMessage = "Gagal menyalin model: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            statusText = "Pemilihan file dibatalkan / gagal: \(error.localizedDescription)"
        }
    }

    // MARK: - Chat

    public func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, generationTask == nil, !isGenerating else { return }
        errorMessage = nil
        tokPerSec = nil

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        if messages.count == 1 {
            conversationTitle = String(text.prefix(40))
        }
        scrollVersion += 1
        // Pesan pengguna langsung disimpan, supaya tidak hilang kalau
        // app ditutup di tengah generation.
        persistCurrentConversation()
        Haptics.light()
        startReplyTurn()
    }

    /// Buat ulang jawaban terakhir (Fase 2): hapus pesan asisten
    /// terakhir, lalu jalankan generation ulang atas riwayat yang sama
    /// tanpa menambahkan pesan pengguna baru.
    public func regenerateLastAnswer() {
        guard !isGenerating, generationTask == nil else { return }
        guard let last = messages.last, last.role == .assistant,
              !last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard messages.contains(where: { $0.role == .user }) else { return }
        messages.removeLast()
        errorMessage = nil
        persistCurrentConversation()
        Haptics.light()
        startReplyTurn()
    }

    /// Ubah pesan pengguna lalu kirim ulang (Fase 2): semua pesan
    /// setelah pesan yang diubah dibuang, isi pesan diganti, lalu
    /// generation dijalankan ulang dari titik itu.
    public func editUserMessage(id: UUID, newContent: String) {
        guard !isGenerating, generationTask == nil else { return }
        let text = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user else { return }
        stop()
        messages = Array(messages[..<index]) + [ChatMessage(id: id, role: .user, content: text)]
        if index == 0 {
            conversationTitle = String(text.prefix(40))
        }
        errorMessage = nil
        persistCurrentConversation()
        Haptics.light()
        startReplyTurn()
    }

    /// Satu giliran generation: wadah asisten kosong, render prompt,
    /// (opsional) orkestrasi tool agent, streaming, outcome, persist.
    /// Dipakai `send`, `regenerateLastAnswer`, dan `editUserMessage`.
    private func startReplyTurn() {
        generationTask = Task {
            defer {
                isGenerating = false
                generationTask = nil
            }

            // Load malas: pesan pertama juga memuat model kalau belum.
            if !(await engine.isLoaded) {
                await loadModel()
                guard await engine.isLoaded else { return }
            }

            // Pesan assistant kosong sebagai wadah streaming.
            let assistantMessage = ChatMessage(role: .assistant, content: "")
            messages.append(assistantMessage)
            let assistantId = assistantMessage.id
            isGenerating = true
            statusText = "Menjawab…"

            // Render seluruh riwayat (tanpa wadah kosong) + system prompt.
            // Template .auto diselesaikan dari metadata model ter-load.
            // Blok <think> dibuang dari riwayat: penalaran giliran lama
            // tidak boleh memakan konteks giliran berikutnya, dan tidak
            // boleh dikirim kembali ke model. Pesan asisten yang isinya
            // hanya think (generation terpotong di tengah berpikir)
            // dibuang dari riwayat karena tidak membawa jawaban apa pun.
            let history = messages.filter { $0.id != assistantId }
                .map { ChatMessage(id: $0.id, role: $0.role, content: ThinkBlock.stripped($0.content)) }
                .filter { !($0.role == .assistant && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            var prompt = ChatTemplate.render(
                kind: ChatTemplate.resolve(kind: templateKind, metadata: loadedDescriptor?.chatTemplate),
                systemPrompt: systemPrompt,
                messages: history
            )

            // MARK: Orkestrasi agent (Fase 2 + Agent), dua langkah.
            //
            // Langkah 1 (diam, tanpa streaming): generation yang sama
            // dengan instruksi tool tambahan. Model boleh menjawab
            // biasa (teks itu yang ditampilkan) atau mengeluarkan SATU
            // blok JSON tool-call. Generation ini memakai parameter
            // penuh supaya jawaban biasa tidak terpotong; kalau model
            // memang memanggil tool, generation berhenti sendiri di
            // EOS sesudah blok JSON.
            //
            // Langkah 2 (hanya kalau ada tool call): konfirmasi kalau
            // tool-nya wajib konfirmasi, eksekusi tool, lalu generation
            // kedua — yang di-stream ke bubble — dengan hasil tool
            // sebagai pesan system di riwayat prompt.
            //
            // Kalau langkah 1 gagal/dibatalkan, perlakuannya sama
            // seperti kegagalan generation biasa (return lebih awal).
            // Kalau langkah 1 menghasilkan teks kosong (mis. terpotong
            // di tengah blok <think>), jatuh ke generation normal di
            // bawah supaya pengguna tetap mendapat jawaban.
            if !ToolPreferences.enabledTools.isEmpty {
                let toolSystemPrompt = systemPrompt + "\n\n" + ToolPrompt.preamble(for: ToolPreferences.enabledTools)
                let decisionPrompt = ChatTemplate.render(
                    kind: ChatTemplate.resolve(kind: templateKind, metadata: loadedDescriptor?.chatTemplate),
                    systemPrompt: toolSystemPrompt,
                    messages: history
                )
                statusText = "Memeriksa apakah perlu tool…"
                let decision = await collectGeneration(prompt: decisionPrompt, parameters: parameters)

                if let failure = decision.failure {
                    removeMessageIfEmpty(assistantId)
                    statusText = failure.errorDescription ?? failure.localizedDescription
                    errorMessage = failure.errorDescription
                    Haptics.error()
                    return
                }
                if decision.outcome == .cancelled || Task.isCancelled {
                    removeMessageIfEmpty(assistantId)
                    statusText = "Dibatalkan."
                    return
                }

                let strippedDecision = ThinkBlock.stripped(decision.text)
                if let call = ToolCallParser.parse(from: strippedDecision) {
                    if call.tool.requiresConfirmation {
                        statusText = "Menunggu konfirmasi tool…"
                        let confirmed = await requestToolConfirmation(call)
                        if Task.isCancelled {
                            removeMessageIfEmpty(assistantId)
                            statusText = "Dibatalkan."
                            return
                        }
                        guard confirmed else {
                            flush("Tool dibatalkan. Tidak ada aksi yang dijalankan.", to: assistantId)
                            statusText = "Dibatalkan."
                            persistCurrentConversation()
                            return
                        }
                    }
                    statusText = "Menjalankan tool: \(call.tool.displayName)…"
                    let result = await toolExecutor.execute(call)
                    Haptics.success()
                    let historyWithResult = history + [ChatMessage(
                        role: .system,
                        content: "Hasil tool '\(call.tool.rawValue)':\n\(result)\nJawablah pertanyaan pengguna memakai hasil ini. Jangan mengklaim tool belum dijalankan."
                    )]
                    prompt = ChatTemplate.render(
                        kind: ChatTemplate.resolve(kind: templateKind, metadata: loadedDescriptor?.chatTemplate),
                        systemPrompt: systemPrompt,
                        messages: historyWithResult
                    )
                    statusText = "Menjawab…"
                } else {
                    let answer = ToolCallParser.strippingToolBlock(from: strippedDecision)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !answer.isEmpty {
                        flush(answer, to: assistantId)
                        statusText = "Selesai."
                        Haptics.success()
                        persistCurrentConversation()
                        return
                    }
                    // Teks keputusan kosong: jatuh ke generation normal.
                }
            }

            let stream = await engine.generate(prompt: prompt, parameters: parameters)
            var pendingText = ""
            var lastFlush = ContinuousClock().now
            var outcome: DoneReason?
            var failure: AppError?

            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .token(let piece):
                    pendingText += piece
                    let now = ContinuousClock().now
                    if now - lastFlush >= .milliseconds(50) {
                        flush(pendingText, to: assistantId)
                        pendingText = ""
                        lastFlush = now
                    }
                case .stats(let rate):
                    tokPerSec = rate
                case .usage(let promptTokens, let generatedTokens, let nCtx):
                    recordUsage(promptTokens: promptTokens, generatedTokens: generatedTokens, nCtx: nCtx)
                case .done(let reason):
                    outcome = reason
                case .failed(let error):
                    failure = error
                }
            }

            // Sisa buffer selalu di-flush, apa pun alasan stream berakhir.
            if !pendingText.isEmpty {
                flush(pendingText, to: assistantId)
            }

            if let failure {
                removeMessageIfEmpty(assistantId)
                statusText = failure.errorDescription ?? failure.localizedDescription
                errorMessage = failure.errorDescription
                Haptics.error()
                return
            }

            switch outcome {
            case .endOfTurn, .maxTokens:
                statusText = "Selesai."
                Haptics.success()
            case .contextOverflow:
                removeMessageIfEmpty(assistantId)
                let detail = "Riwayat percakapan melebihi konteks model (n_ctx \(actualNCtx)). Mulai percakapan baru."
                statusText = detail
                errorMessage = detail
                Haptics.error()
            case .cancelled, .none:
                // Stop oleh pengguna: teks parsial dipertahankan kalau
                // ada; wadah kosong dihapus supaya tidak ada bubble kosong.
                removeMessageIfEmpty(assistantId)
                statusText = "Dibatalkan."
            }

            // Generation selesai / gagal / dibatalkan: simpan state
            // akhir percakapan, termasuk jawaban parsial kalau ada.
            persistCurrentConversation()
        }
    }

    /// Stop yang benar-benar menghentikan decode: membatalkan Task
    /// konsumen membuat loop `for await` break, menutup stream, dan
    /// `onTermination` di engine membatalkan Task produsen decode.
    /// Kalau ada dialog konfirmasi tool yang sedang menunggu, dialog
    /// itu ditolak (tool tidak dijalankan).
    public func stop() {
        if pendingToolContinuation != nil {
            resolvePendingToolCall(confirmed: false)
        }
        generationTask?.cancel()
        generationTask = nil
        statusText = "Stop diminta — menunggu decode berhenti…"
    }

    // MARK: - Agent: generation terkumpul & konfirmasi tool

    /// Hasil satu generation yang dijalankan tanpa streaming ke bubble
    /// (langkah keputusan tool). Teks tetap dikumpulkan penuh.
    private struct CollectedGeneration {
        var text = ""
        var outcome: DoneReason?
        var failure: AppError?
    }

    /// Jalankan generation dan kumpulkan seluruh teksnya tanpa
    /// menampilkan ke bubble. Dipakai langkah keputusan tool.
    private func collectGeneration(
        prompt: String,
        parameters: SamplingParameters
    ) async -> CollectedGeneration {
        var result = CollectedGeneration()
        let stream = await engine.generate(prompt: prompt, parameters: parameters)
        for await event in stream {
            if Task.isCancelled { break }
            switch event {
            case .token(let piece):
                result.text += piece
            case .stats(let rate):
                tokPerSec = rate
            case .usage(let promptTokens, let generatedTokens, let nCtx):
                recordUsage(promptTokens: promptTokens, generatedTokens: generatedTokens, nCtx: nCtx)
            case .done(let reason):
                result.outcome = reason
            case .failed(let error):
                result.failure = error
            }
        }
        return result
    }

    /// Simpan angka pemakaian konteks terakhir untuk bar konteks.
    private func recordUsage(promptTokens: Int, generatedTokens: Int, nCtx: Int) {
        contextPromptTokens = promptTokens
        contextGeneratedTokens = generatedTokens
        contextLimit = nCtx
    }

    /// Tampilkan dialog konfirmasi dan tunggu jawaban pengguna.
    /// Tool yang tidak wajib konfirmasi tidak pernah memanggil ini
    /// (pemanggil mengecek `requiresConfirmation` dulu).
    private func requestToolConfirmation(_ call: ToolCallRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingToolContinuation = continuation
            pendingToolCall = PendingToolCall(request: call)
        }
    }

    /// Jawaban dialog konfirmasi tool, dari `ChatView`. Me-resume
    /// continuation tepat sekali; pemanggilan kedua tanpa continuation
    /// yang menunggu tidak melakukan apa-apa.
    public func resolvePendingToolCall(confirmed: Bool) {
        guard let continuation = pendingToolContinuation else { return }
        pendingToolContinuation = nil
        pendingToolCall = nil
        Haptics.light()
        continuation.resume(returning: confirmed)
    }

    public func startNewChat() {
        stop()
        // Simpan dulu percakapan yang ditinggalkan, baru lupakan.
        persistCurrentConversation()
        forgetCurrentConversation()
        tokPerSec = nil
        errorMessage = nil
        statusText = isModelLoaded ? "Model siap." : "Belum ada model."
        scrollVersion += 1
    }

    /// Lupakan percakapan yang sedang dibuka TANPA menyimpannya.
    /// Dipakai setelah percakapan dihapus dari daftar (tidak ada lagi
    /// yang bisa disimpan) dan oleh `startNewChat` setelah penyimpanan
    /// eksplisit. Model yang ter-load TIDAK di-unload: ganti percakapan
    /// tidak berarti ganti model.
    public func forgetCurrentConversation() {
        currentConversationID = nil
        messages = []
        conversationTitle = "Percakapan baru"
    }

    public func dismissError() {
        errorMessage = nil
    }

    // MARK: - Persistensi & multi-conversation (Fase D)

    /// Pulihkan percakapan yang terakhir diubah saat app baru dibuka.
    /// Sekali saja per masa hidup ViewModel, dan hanya kalau belum ada
    /// pesan di memori (mis. setelah restore, pengguna bebas pindah ke
    /// percakapan lain tanpa takut tertimpa restore ini).
    public func restoreLatestConversationIfNeeded() {
        guard !hasRestoredLatest else { return }
        hasRestoredLatest = true
        guard messages.isEmpty else { return }
        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let latest = try? modelContext.fetch(descriptor).first else { return }
        currentConversationID = latest.id
        messages = latest.orderedMessages.map(\.chatMessage)
        conversationTitle = latest.title
        scrollVersion += 1
    }

    /// Buka percakapan tersimpan. Percakapan yang sedang dibuka disimpan
    /// dulu (kecuali yang dibuka adalah percakapan itu sendiri). Model
    /// yang ter-load tidak di-unload; generation yang sedang berjalan
    /// dihentikan dulu supaya jawabannya tidak mendarat di percakapan
    /// yang salah.
    public func loadConversation(_ conversation: Conversation) {
        stop()
        if conversation.id != currentConversationID {
            persistCurrentConversation()
        }
        currentConversationID = conversation.id
        messages = conversation.orderedMessages.map(\.chatMessage)
        conversationTitle = conversation.title
        tokPerSec = nil
        errorMessage = nil
        statusText = isModelLoaded ? "Model siap." : "Belum ada model."
        scrollVersion += 1
    }

    /// Judul yang disimpan: 40 karakter pertama pesan pengguna pertama,
    /// sama seperti judul di navigation bar. Tanpa pesan pengguna,
    /// judul default yang dipakai.
    private func titleForPersistence() -> String {
        if let firstUser = messages.first(where: { $0.role == .user }) {
            return String(firstUser.content.prefix(40))
        }
        return "Percakapan baru"
    }

    /// Simpan state `messages` saat ini ke SwiftData (upsert berdasarkan
    /// ID pesan). Tidak melakukan apa-apa untuk percakapan kosong.
    /// Kegagalan save diabaikan secara sengaja (`try?`): chat di memori
    /// tetap jalan; kehilangan riwayat tersimpan lebih baik daripada
    /// crash atau banner error di tengah percakapan.
    private func persistCurrentConversation() {
        guard !messages.isEmpty else { return }
        conversationTitle = titleForPersistence()
        let now = Date()

        let conversation: Conversation
        if let wantedID = currentConversationID {
            let all = (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? []
            if let existing = all.first(where: { $0.id == wantedID }) {
                conversation = existing
            } else {
                conversation = Conversation(id: wantedID, title: conversationTitle, createdAt: now, updatedAt: now)
                modelContext.insert(conversation)
            }
        } else {
            conversation = Conversation(title: conversationTitle, createdAt: now, updatedAt: now)
            currentConversationID = conversation.id
            modelContext.insert(conversation)
        }
        conversation.title = conversationTitle
        conversation.updatedAt = now

        var byID: [UUID: StoredMessage] = [:]
        for stored in conversation.messages {
            byID[stored.id] = stored
        }
        var synced: [StoredMessage] = []
        for (index, message) in messages.enumerated() {
            if let stored = byID[message.id] {
                stored.content = message.content
                stored.roleRaw = message.role.rawValue
                stored.sortIndex = index
                synced.append(stored)
            } else {
                let stored = StoredMessage(
                    id: message.id,
                    role: message.role,
                    content: message.content,
                    sortIndex: index,
                    conversation: conversation
                )
                modelContext.insert(stored)
                synced.append(stored)
            }
        }
        for stored in conversation.messages where !messages.contains(where: { $0.id == stored.id }) {
            modelContext.delete(stored)
        }
        conversation.messages = synced
        try? modelContext.save()
    }

    // MARK: - Bantuan internal

    private func flush(_ text: String, to messageId: UUID) {
        guard !text.isEmpty,
              let index = messages.firstIndex(where: { $0.id == messageId })
        else { return }
        let current = messages[index]
        messages[index] = ChatMessage(id: current.id, role: current.role, content: current.content + text)
        scrollVersion += 1
    }

    private func removeMessageIfEmpty(_ messageId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].content.isEmpty
        else { return }
        messages.remove(at: index)
        scrollVersion += 1
    }
}
