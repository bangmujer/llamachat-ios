import SwiftUI
import UniformTypeIdentifiers

/// Model Manager Fase C + Katalog: daftar model di perangkat, hapus,
/// impor dari Files, katalog model terkurasi, dan download dari URL —
/// semua lewat `ModelDownloadManager` (background URLSession, segmen
/// paralel).
///
/// Setelah download selesai atau file diimpor/dihapus, daftar
/// di-refresh; model yang baru selesai di-download TIDAK otomatis
/// di-load — pengguna menekan "Muat" supaya load yang berat selalu
/// eksplisit.
public struct ModelManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var downloader = ModelDownloadManager.shared
    @AppStorage("llamachat.downloadConnections") private var connections = 8

    @State private var models: [ModelDescriptor] = []
    @State private var listError: String?
    @State private var showingImporter = false
    @State private var modelToDelete: ModelDescriptor?
    /// Download yang menunggu konfirmasi Batal: tombol Batal menghapus
    /// progres yang sudah tersimpan, jadi tidak boleh jalan dari satu
    /// ketukan yang tak sengaja (Jeda dan Batal bersebelahan).
    @State private var cancelTarget: ModelDownloadManager.DownloadItem?
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

                Section {
                    ForEach(ModelCatalog.all) { entry in
                        catalogRow(entry)
                    }
                } header: {
                    Text("Katalog Model — cocok untuk HP 6 GB")
                } footer: {
                    Text("Semua model di katalog ini berformat GGUF dan total pemakaian RAM-nya (file + KV cache + overhead) muat di bawah guard 3,8 GB. Ukuran RAM adalah perkiraan untuk n_ctx 2048.")
                }

                if !downloader.downloads.isEmpty {
                    Section("Download") {
                        ForEach(downloader.downloads) { item in
                            downloadRow(item)
                        }
                    }
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
                    Picker("Koneksi per file", selection: $connections) {
                        ForEach(1...ModelDownloadManager.maxConnections, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("File dipecah menjadi segmen sebanyak koneksi dan diunduh bersamaan, seperti download manager. Lebih banyak tidak selalu lebih cepat — server dan jaringan yang membatasi. Pengaturan ini berlaku untuk download yang baru dimulai.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Mulai Download") {
                        startDownload()
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("Download hanya dimulai dari tombol ini, dengan URL yang kamu isi sendiri. Ukuran yang diharapkan dipakai untuk verifikasi setelah download selesai.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Impor dari Files") {
                    Button("Pilih File (.gguf)…") {
                        showingImporter = true
                    }
                    Text("File disalin ke folder Models di dalam app.")
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

                Section {
                    Text("Build ini: Jeda memakai resume per byte (progres tidak hilang); tombol Batal meminta konfirmasi dulu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .onChange(of: downloader.downloads) { _, newDownloads in
                if newDownloads.contains(where: { $0.state == .finished }) {
                    refresh()
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                // Sama seperti ChatView: hanya .data. Filter UTI kustom
                // .gguf tidak bisa diandalkan di picker; validasi magic
                // GGUF di import adalah gerbang sebenarnya.
                allowedContentTypes: [.data],
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
            .alert(
                "Batalkan download?",
                isPresented: Binding(
                    get: { cancelTarget != nil },
                    set: { if !$0 { cancelTarget = nil } }
                ),
                presenting: cancelTarget
            ) { item in
                Button("Batalkan download", role: .destructive) {
                    downloader.cancelDownload(id: item.id)
                }
                Button("Lanjutkan download", role: .cancel) {}
            } message: { item in
                Text("Progres \(item.fileName) yang sudah tersimpan akan dihapus dan harus diunduh ulang dari awal.")
            }
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: CatalogModel) -> some View {
        let downloaded = models.contains { $0.fileName == entry.fileName }
        let active = downloader.downloads.first { $0.fileName == entry.fileName }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                    Text("\(entry.quant) · \(entry.sizeDisplay) · RAM \(entry.ramEstimateDisplay)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if downloaded {
                    Text("Terunduh")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let active {
                    catalogDownloadState(active)
                } else {
                    Button("Unduh") {
                        downloader.startDownload(
                            url: entry.url,
                            fileName: entry.fileName,
                            expectedSizeBytes: entry.exactSizeBytes
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text(entry.tagline)
                .font(.subheadline)
            Text("Cocok untuk: \(entry.strengths)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let note = entry.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func catalogDownloadState(_ item: ModelDownloadManager.DownloadItem) -> some View {
        switch item.state {
        case .finished:
            Text("Selesai")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed:
            Button("Coba Lagi") { downloader.resumeDownload(id: item.id) }
                .buttonStyle(.bordered)
        case .paused:
            Button("Lanjutkan") { downloader.resumeDownload(id: item.id) }
                .buttonStyle(.bordered)
        default:
            Text("\(Int(item.progress * 100))%")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func downloadRow(_ item: ModelDownloadManager.DownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.fileName)
                .lineLimit(1)
            switch item.state {
            case .downloading, .queued, .probing:
                ProgressView(value: item.progress) {
                    Text(statusText(for: item))
                }
                if item.segmentCount > 1 {
                    SegmentStripView(fractions: item.segmentFractions)
                }
                Text(detailText(for: item))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .verifying:
                HStack {
                    ProgressView()
                    Text("Memverifikasi \(item.fileName)…")
                }
            case .paused:
                ProgressView(value: item.progress) {
                    Text("Terjeda: \(item.fileName)")
                }
                Text(detailText(for: item))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .finished:
                Text("Selesai: \(item.fileName). Tekan Muat Model Pertama untuk memuatnya.")
                    .foregroundStyle(.secondary)
            case .failed:
                Text(item.errorMessage ?? "Download gagal.")
                    .foregroundStyle(.red)
            }
            HStack {
                switch item.state {
                case .downloading, .queued, .probing:
                    Button("Jeda") { downloader.pauseDownload(id: item.id) }
                    Button("Batal", role: .destructive) { cancelTarget = item }
                case .paused, .failed:
                    Button("Lanjutkan") { downloader.resumeDownload(id: item.id) }
                    Button("Batal", role: .destructive) { cancelTarget = item }
                case .verifying:
                    EmptyView()
                case .finished:
                    Button("Hapus dari Daftar") { downloader.cancelDownload(id: item.id) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(for item: ModelDownloadManager.DownloadItem) -> String {
        switch item.state {
        case .queued:
            return "Antre: \(item.fileName)"
        case .probing:
            return "Memeriksa file: \(item.fileName)"
        case .downloading:
            return "Mengunduh \(item.fileName)"
        case .paused, .verifying, .finished, .failed:
            return item.fileName
        }
    }

    private func detailText(for item: ModelDownloadManager.DownloadItem) -> String {
        let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
        let total = item.totalBytes > 0
            ? ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
            : "ukuran tidak diketahui"
        var text = "\(received) / \(total)"
        if item.segmentCount > 1 {
            text += " · segmen \(item.segmentsDone)/\(item.segmentCount)"
            if item.state == .downloading, item.activeSegments > 0 {
                text += " (\(item.activeSegments) berjalan)"
            }
        }
        if item.speedBytesPerSec > 0 {
            text += " · \(ByteCountFormatter.string(fromByteCount: Int64(item.speedBytesPerSec), countStyle: .file))/dtk"
        }
        return text
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
        downloader.startDownload(url: url, fileName: fileName, expectedSizeBytes: expected)
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

/// Strip progres per segmen: satu sel per segmen, terisi sesuai fraksi
/// segmen itu (0 = kosong, 1 = selesai penuh). Tujuannya supaya
/// terlihat segmen-segmen memang terisi bersamaan — angka
/// "segmen X/Y" hanya naik kalau satu segmen penuh selesai, yang
/// dengan segmen ~125 MB terlihat macet berlama-lama.
private struct SegmentStripView: View {
    let fractions: [Double]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(fractions.indices, id: \.self) { index in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.25))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * max(0, min(1, fractions[index])))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 6)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Progres per segmen")
    }
}
