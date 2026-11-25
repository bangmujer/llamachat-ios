import SwiftUI

/// Settings Fase C.
///
/// Isi: model yang sedang ter-load + Model Manager, system prompt,
/// parameter sampling per-model, dan pilihan template chat.
/// Semua perubahan parameter disimpan per-model (`ModelSettingsStore`)
/// saat Terapkan ditekan; perubahan n_ctx memicu load ulang model
/// (lihat `ChatViewModel.applyParameters`).
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    @State private var showingModelManager = false
    @State private var showingPromptEditor = false

    @State private var temperature: Double = 0.7
    @State private var topP: Double = 0.9
    @State private var topK: Int = 40
    @State private var repeatPenalty: Double = 1.1
    @State private var maxTokens: Int = 256
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
                    Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 64...1024, step: 64)
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
