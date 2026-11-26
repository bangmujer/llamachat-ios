import SwiftUI

/// Settings Fase C/D + Fase 2.
///
/// Isi: model yang sedang ter-load + Model Manager, system prompt,
/// parameter sampling per-model, pilihan template chat, tampilan
/// (Fase 2: skema warna + haptik), dan tools agent (Fase 2 + Agent:
/// aktif/nonaktif per tool, langsung tersimpan saat diubah).
/// Semua perubahan parameter disimpan per-model (`ModelSettingsStore`)
/// saat Terapkan ditekan; perubahan n_ctx memicu load ulang model
/// (lihat `ChatViewModel.applyParameters`).
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    @AppStorage("llamachat.colorScheme") private var colorSchemeChoice = AppearanceChoice.system.rawValue
    @AppStorage("llamachat.agentEnabled") private var agentEnabled = true
    @AppStorage("llamachat.voiceModeEnabled") private var voiceModeEnabled = false
    @State private var hapticsEnabled = true

    @State private var googleApiKey = ""
    @State private var googleEngineID = ""

    @State private var showingModelManager = false
    @State private var showingPromptEditor = false

    @State private var temperature: Double = 0.7
    @State private var topP: Double = 0.9
    @State private var topK: Int = 40
    @State private var repeatPenalty: Double = 1.1
    @State private var maxTokens: Int = 1024
    @State private var nCtx: Int = 2048
    @State private var templateKind: ChatTemplateKind = .auto
    @State private var isApplying = false

    private let nCtxOptions = [512, 1024, 2048, 4096]

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    if let name = viewModel.modelName {
                        LabeledContent("Ter-load", value: name)
                        LabeledContent("Konteks (n_ctx)", value: "\(viewModel.actualNCtx)")
                    } else {
                        Text("Belum ada model ter-load.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Kelola Model…") {
                        showingModelManager = true
                    }
                }

                Section("System Prompt") {
                    Text(viewModel.systemPrompt)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                    Button("Ubah System Prompt…") {
                        showingPromptEditor = true
                    }
                }

                Section("Tampilan") {
                    Picker("Skema warna", selection: $colorSchemeChoice) {
                        ForEach(AppearanceChoice.allCases, id: \.rawValue) { choice in
                            Text(choice.displayName).tag(choice.rawValue)
                        }
                    }
                    Toggle("Haptik", isOn: $hapticsEnabled)
                        .onChange(of: hapticsEnabled) { _, newValue in
                            Haptics.setEnabled(newValue)
                        }
                }

                Section("Suara") {
                    Toggle(isOn: $voiceModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mode suara")
                            Text("Voice note yang selesai ditranskripsi langsung dikirim, dan jawaban asisten dibacakan otomatis. Bila nonaktif, transkripsi masuk ke kolom tulis untuk diperiksa dulu sebelum dikirim.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Voice note memakai pengenalan ucapan iOS (butuh izin mikrofon; model bahasa bisa memakai jaringan bila belum terunduh di perangkat). Tombol speaker di bawah tiap jawaban asisten membacakan jawaban kapan pun, apa pun pengaturan ini.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Agent & Tools") {
                    Toggle(isOn: $agentEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mode Agen")
                            Text("Bila nonaktif, chat menjawab langsung tanpa langkah memutuskan tool — lebih cepat. Pilihan tool di bawah tetap tersimpan.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Tools hanya yang bisa dilakukan app iOS biasa. App tidak bisa membaca isi aplikasi lain dan tidak bisa mengubah pengaturan sistem. Tool tulis selalu minta konfirmasi sebelum dijalankan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(AgentTool.allCases) { tool in
                        Toggle(isOn: Binding(
                            get: { ToolPreferences.isEnabled(tool) },
                            set: { ToolPreferences.setEnabled(tool, $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.displayName)
                                Text(tool.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!agentEnabled)
                    }
                    Text("Tool yang nonaktif tidak ditawarkan ke model. Tool baca yang butuh izin (Kalender, Kontak) meminta izin iOS saat pertama dipakai. Tool internet (Cari di internet, Buka halaman web) mengirim query/URL ke mesin pencari dan situs terkait — nonaktif secara default, aktifkan sendiri bila perlu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Pencarian Google (opsional)") {
                    Text("Isi keduanya untuk memakai Google sebagai mesin pencari tool \"Cari di internet\" (Programmable Search API, gratis 100 pencarian/hari). Keduanya disimpan aman di Keychain HP ini dan hanya dikirim ke Google saat pencarian dipakai. Kosongkan untuk tetap memakai DuckDuckGo + Wikipedia.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SecureField("API Key Google", text: $googleApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: googleApiKey) { _, newValue in
                            WebSearchSettings.setApiKey(newValue)
                        }
                    TextField("Search Engine ID (CX)", text: $googleEngineID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: googleEngineID) { _, newValue in
                            WebSearchSettings.setEngineID(newValue)
                        }
                    LabeledContent(
                        "Status Google",
                        value: googleApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || googleEngineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Belum terkonfigurasi" : "Terkonfigurasi"
                    )
                }

                Section("Parameter Sampling") {
                    VStack(alignment: .leading) {
                        Text("Temperature: \(temperature, specifier: "%.2f")")
                        Slider(value: $temperature, in: 0...2, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Top-p: \(topP, specifier: "%.2f")")
                        Slider(value: $topP, in: 0...1, step: 0.05)
                    }
                    Stepper("Top-k: \(topK)", value: $topK, in: 0...100, step: 5)
                    VStack(alignment: .leading) {
                        Text("Repeat penalty: \(repeatPenalty, specifier: "%.2f")")
                        Slider(value: $repeatPenalty, in: 1...2, step: 0.05)
                    }
                    Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 64...2048, step: 64)
                    Picker("Konteks (n_ctx)", selection: $nCtx) {
                        ForEach(nCtxOptions, id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    Text("Mengganti n_ctx akan memuat ulang model. Parameter lain berlaku untuk balasan berikutnya.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Template Chat") {
                    Picker("Template", selection: $templateKind) {
                        ForEach(ChatTemplateKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    if templateKind == .auto, let descriptor = viewModel.loadedDescriptor {
                        let detected = ChatTemplate.detect(from: descriptor.chatTemplate)
                        Text("Terdeteksi dari model: \(detected.displayName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Tentang") {
                    LabeledContent("Versi", value: appVersionText)
                    LabeledContent("Dukungan .gguf", value: ggufSupportText)
                    Text("Dukungan .gguf dibaca dari Info.plist build yang terpasang. Kalau tertulis tidak aktif, build yang terpasang masih build lama — install ulang IPA terbaru.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(isApplying ? "Menerapkan…" : "Terapkan") {
                        apply()
                    }
                    .disabled(isApplying || viewModel.modelName == nil)
                } footer: {
                    Text("Parameter disimpan per-model. Tanpa model ter-load, tidak ada yang bisa diterapkan.")
                }
            }
            .navigationTitle("Pengaturan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
            .onAppear(perform: loadDraft)
            .sheet(isPresented: $showingModelManager) {
                ModelManagerView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingPromptEditor) {
                PromptEditorView(initialText: viewModel.systemPrompt) { newValue in
                    viewModel.setSystemPrompt(newValue)
                }
            }
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// "Aktif" kalau build yang terpasang mendeklarasikan tipe dokumen
    /// GGUF di Info.plist-nya. Dipakai untuk membedakan build lama vs
    /// build baru saat mendiagnosis masalah import di device.
    private var ggufSupportText: String {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] else {
            return "Tidak aktif"
        }
        let hasGGUF = types.contains { type in
            let contentTypes = type["LSItemContentTypes"] as? [String] ?? []
            let extensions = type["CFBundleTypeExtensions"] as? [String] ?? []
            return contentTypes.contains("org.ggml.gguf") || extensions.contains("gguf")
        }
        return hasGGUF ? "Aktif" : "Tidak aktif"
    }

    private func loadDraft() {
        let params = viewModel.parameters
        temperature = Double(params.temperature)
        topP = Double(params.topP)
        topK = Int(params.topK)
        repeatPenalty = Double(params.repeatPenalty)
        maxTokens = Int(params.maxTokens)
        nCtx = params.nCtx
        templateKind = viewModel.templateKind
        hapticsEnabled = Haptics.isEnabled
        googleApiKey = WebSearchSettings.apiKey
        googleEngineID = WebSearchSettings.engineID
    }

    private func apply() {
        isApplying = true
        let params = SamplingParameters(
            temperature: Float(temperature),
            topP: Float(topP),
            topK: Int32(topK),
            repeatPenalty: Float(repeatPenalty),
            penaltyLastN: viewModel.parameters.penaltyLastN,
            maxTokens: maxTokens,
            nCtx: nCtx
        )
        Task {
            await viewModel.applyParameters(params, templateKind: templateKind)
            isApplying = false
            dismiss()
        }
    }
}
