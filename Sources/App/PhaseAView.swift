import SwiftUI
import UniformTypeIdentifiers

/// HARNESS FASE A — SEMENTARA, diganti `ChatView` di Fase B.
///
/// Tugasnya hanya tiga:
/// 1. Memilih file .gguf dari Files dan menyalinnya ke
///    Application Support/Models/ (potongan kecil dari Model Manager
///    Fase C, ditarik ke depan supaya Fase A BISA diuji di device tanpa
///    Mac/Xcode — tanpa ini tidak ada cara memasukkan model ke app
///    yang di-install lewat TrollStore).
/// 2. Memuat model lewat `LlamaEngine` dan men-generate satu prompt.
/// 3. Menampilkan log + teks hasil di layar, karena tidak ada konsol
///    Xcode saat install lewat TrollStore.
///
/// File ini DIHAPUS / diganti di Fase B. Jangan menambah fitur chat di sini.
struct PhaseAView: View {
    let engine: LlamaEngine

    @State private var statusText = "Idle — belum ada model."
    @State private var generatedText = ""
    @State private var tokPerSec: Double?
    @State private var logLines: [String] = []
    @State private var isBusy = false
    @State private var showingPicker = false
    @State private var generationTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LlamaChat — Fase A")
                    .font(.title2)
                    .bold()
                Text("Harness sementara. Chat UI datang di Fase B.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(statusText)
                    .font(.body)

                if let tokPerSec {
                    Text(String(format: "Kecepatan: %.1f token/detik", tokPerSec))
                        .font(.body)
                        .monospacedDigit()
                }

                HStack(spacing: 12) {
                    Button("Pilih Model (.gguf)") {
                        showingPicker = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                    Button("Muat & Generate") {
                        runSmokeTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)

                    Button("Stop") {
                        stopGeneration()
                    }
                    .buttonStyle(.bordered)
                    .disabled(generationTask == nil)
                }

                Text("Hasil:")
                    .font(.headline)
                Text(generatedText.isEmpty ? "(belum ada hasil)" : generatedText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("Log:")
                    .font(.headline)
                Text(logLines.joined(separator: "\n"))
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [ggufType],
            allowsMultipleSelection: false
        ) { result in
            importPickedModel(result: result)
        }
    }

    private var ggufType: UTType {
        UTType(filenameExtension: "gguf") ?? .data
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
        print("[PhaseA] \(line)")
    }

    private func importPickedModel(result: Result<[URL], Error>) {
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
                    let size = try ModelLoader.fileSizeBytes(at: destination)
                    statusText = "Model tersalin: \(destination.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
                    appendLog("Model tersalin ke \(destination.path)")
                } catch {
                    statusText = "Gagal menyalin model: \(error.localizedDescription)"
                    appendLog("Gagal menyalin model: \(error.localizedDescription)")
                }
            }
        case .failure(let error):
            statusText = "Pemilihan file dibatalkan / gagal: \(error.localizedDescription)"
            appendLog("Pemilihan file gagal: \(error.localizedDescription)")
        }
    }

    private func runSmokeTest() {
        guard generationTask == nil else { return }
        isBusy = true
        generatedText = ""
        tokPerSec = nil
        statusText = "Memuat model…"
        appendLog("Mulai smoke test.")

        generationTask = Task {
            defer {
                isBusy = false
                generationTask = nil
            }

            // Load. Method actor ini berjalan di luar main thread.
            let descriptor: ModelDescriptor
            do {
                let parameters = SamplingParameters.defaultForCurrentDevice()
                descriptor = try await engine.loadFirstModel(parameters: parameters)
                let actualCtx = await engine.actualNCtx
                statusText = "Model ter-load: \(descriptor.fileName) (\(descriptor.displaySize)), n_ctx aktual: \(actualCtx)"
                appendLog("Model ter-load: \(descriptor.fileName), n_params=\(descriptor.nParams.map(String.init) ?? "-"), n_layer=\(descriptor.nLayer.map(String.init) ?? "-")")
            } catch let error as AppError {
                statusText = error.localizedDescription
                appendLog("Load gagal: \(error.localizedDescription)")
                return
            } catch {
                statusText = error.localizedDescription
                appendLog("Load gagal: \(error.localizedDescription)")
                return
            }

            let prompt = ChatTemplate.render(
                kind: .chatML,
                systemPrompt: "Kamu adalah asisten yang menjawab singkat dalam Bahasa Indonesia.",
                messages: [
                    ChatMessage(role: .user, content: "Jelaskan apa itu fotosintesis dalam satu kalimat.")
                ]
            )
            appendLog("Prompt:\n\(prompt)")
            statusText = "Generating…"
            let parameters = SamplingParameters.defaultForCurrentDevice()

            let stream = await engine.generate(prompt: prompt, parameters: parameters)
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .token(let piece):
                    generatedText += piece
                case .stats(let rate):
                    tokPerSec = rate
                    appendLog(String(format: "Stats: %.1f tok/detik", rate))
                case .done(let reason):
                    statusText = "Selesai: \(reason)"
                    appendLog("Done: \(reason)")
                case .failed(let error):
                    statusText = error.localizedDescription
                    appendLog("Generation gagal: \(error.localizedDescription)")
                }
            }
            appendLog("Stream selesai. Panjang hasil: \(generatedText.count) karakter.")
        }
    }

    private func stopGeneration() {
        // Membatalkan Task konsumen membuat loop `for await` break, yang
        // menutup stream, yang memicu onTermination di engine dan
        // membatalkan Task produsen decode. Lihat LlamaEngine.generate.
        generationTask?.cancel()
        generationTask = nil
        statusText = "Stop diminta — menunggu decode berhenti…"
        appendLog("Stop diminta oleh pengguna.")
    }
}
