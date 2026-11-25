import SwiftUI
import UniformTypeIdentifiers

/// Model Manager Fase C: daftar model di perangkat, hapus, impor dari
/// Files, dan download dari URL yang dimasukkan pengguna.
///
/// Download memakai `ModelDownloadManager` (background URLSession).
/// Setelah download selesai atau file diimpor/dihapus, daftar
/// di-refresh; model yang baru selesai di-download TIDAK otomatis
/// di-load — pengguna menekan "Muat" supaya load yang berat selalu
/// eksplisit.
public struct ModelManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var downloader = ModelDownloadManager.shared

    @State private var models: [ModelDescriptor] = []
    @State private var listError: String?
    @State private var showingImporter = false
    @State private var modelToDelete: ModelDescriptor?
    @State private var urlText = ""
    @State private var fileNameText = ""
    @State private var expectedSizeMBText = ""
    @State private var isWorking = false

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Model di perangkat") {
                    if models.isEmpty {
                        Text("Belum ada model .gguf di perangkat.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(models) { descriptor in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(descriptor.fileName)
                                    .lineLimit(1)
                                Text(descriptor.displaySize)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if descriptor.fileName == viewModel.modelName {
                                Text("Ter-load")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Hapus", role: .destructive) {
                                modelToDelete = descriptor
                            }
                        }
                    }
                    if let listError {
                        Text(listError)
                            .foregroundStyle(.red)
                    }
                }

                Section("Impor dari Files") {
                    Button("Pilih File (.gguf)…") {
                        showingImporter = true
                    }
                    Text("File disalin ke folder Models di dalam app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Download dari URL") {
                    TextField("https://…/model.gguf", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Nama file (mis. qwen3-3b-q4_k_m.gguf)", text: $fileNameText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Ukuran yang diharapkan (MB, opsional)", text: $expectedSizeMBText)
                        .keyboardType(.numberPad)
                    downloadControls
                    Text("Download hanya dimulai dari tombol ini, dengan URL yang kamu isi sendiri. Ukuran yang diharapkan dipakai untuk verifikasi setelah download selesai.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Muat Model Pertama") {
                        Task {
                            isWorking = true
                            await viewModel.loadModel()
                            isWorking = false
                            refresh()
                        }
                    }
                    .disabled(isWorking || models.isEmpty)
                }
            }
            .navigationTitle("Model Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
            .onAppear(perform: refresh)
            .onChange(of: downloader.state) { _, newState in
                if case .finished = newState {
                    refresh()
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [UTType.gguf, .data],
                allowsMultipleSelection: false
            ) { result in
                viewModel.importPickedModel(result: result)
                // Salinan selesai di Task ViewModel; refresh tertunda
                // sedikit supaya file sudah ada saat daftar dibaca.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    refresh()
                }
            }
            .alert(
                "Hapus model?",
                isPresented: Binding(
                    get: { modelToDelete != nil },
                    set: { if !$0 { modelToDelete = nil } }
                ),
                presenting: modelToDelete
            ) { descriptor in
                Button("Hapus", role: .destructive) {
                    delete(descriptor)
                }
                Button("Batal", role: .cancel) {}
            } message: { descriptor in
                Text("\(descriptor.fileName) (\(descriptor.displaySize)) akan dihapus dari perangkat.")
            }
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch downloader.state {
        case .idle:
            Button("Mulai Download") {
                startDownload()
            }
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .downloading(let progress, let received, let expected, let fileName):
            VStack(alignment: .leading) {
                ProgressView(value: progress) {
                    Text("Mengunduh \(fileName)")
                }
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(expected > 0 ? ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : "ukuran tidak diketahui")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Jeda") { downloader.pause() }
                    Button("Batal", role: .destructive) { downloader.cancel() }
                }
            }
        case .paused(let progress, let received, let expected, let fileName):
            VStack(alignment: .leading) {
                ProgressView(value: progress) {
                    Text("Terjeda: \(fileName)")
                }
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(expected > 0 ? ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : "ukuran tidak diketahui")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Lanjutkan") { downloader.resumeDownload() }
                    Button("Batal", role: .destructive) { downloader.cancel() }
                }
            }
        case .verifying(let fileName):
            HStack {
                ProgressView()
                Text("Memverifikasi \(fileName)…")
            }
        case .finished(let fileName):
            VStack(alignment: .leading) {
                Text("Selesai: \(fileName). Tekan Muat Model Pertama untuk memuatnya.")
                    .foregroundStyle(.secondary)
                Button("Download Lain") { downloader.cancel() }
            }
        case .failed(let message):
            VStack(alignment: .leading) {
                Text(message)
                    .foregroundStyle(.red)
                Button("Coba Lagi") { downloader.cancel() }
            }
        }
    }

    private func refresh() {
        do {
            models = try ModelLoader.listModels()
            listError = nil
        } catch {
            models = []
            listError = error.localizedDescription
        }
    }

    private func startDownload() {
        let urlString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) else {
            downloader.cancel()
            return
        }
        var fileName = fileNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty {
            fileName = url.lastPathComponent
        }
        var expected: Int64?
        if let mb = Int64(expectedSizeMBText.trimmingCharacters(in: .whitespacesAndNewlines)), mb > 0 {
            expected = mb * 1024 * 1024
        }
        downloader.start(url: url, fileName: fileName, expectedSizeBytes: expected)
    }

    private func delete(_ descriptor: ModelDescriptor) {
        Task {
            isWorking = true
            defer { isWorking = false }
            if descriptor.fileName == viewModel.modelName {
                await viewModel.unloadModel()
            }
            do {
                try ModelLoader.deleteModel(named: descriptor.fileName)
            } catch {
                listError = "Gagal menghapus: \(error.localizedDescription)"
            }
            refresh()
        }
    }
}
