import SwiftUI
import UniformTypeIdentifiers

/// Chat UI Fase B: satu percakapan di memori.
///
/// - `ScrollView` + `LazyVStack` (bukan `List`, sesuai brief) dengan
///   auto-scroll ke pesan terbaru.
/// - Model di-load otomatis saat tampil kalau file .gguf sudah ada di
///   Models/. Kalau belum ada, empty state menawarkan import dari Files
///   (potongan Model Manager Fase C yang dibutuhkan supaya Fase B bisa
///   diuji di device tanpa Mac).
/// - System prompt bisa diubah dari sheet toolbar; perubahan langsung
///   berlaku untuk jawaban berikutnya (disimpan di UserDefaults oleh
///   ViewModel).
/// - Persistensi percakapan (SwiftData, multi-conversation) datang di
///   Fase D; di sini hanya ada satu percakapan dan tombol Percakapan Baru.
struct ChatView: View {
    let engine: LlamaEngine

    @StateObject private var viewModel: ChatViewModel
    @State private var draftText = ""
    @State private var showingPicker = false
    @State private var showingSystemPrompt = false
    @State private var systemPromptDraft = ""

    init(engine: LlamaEngine) {
        self.engine = engine
        _viewModel = StateObject(wrappedValue: ChatViewModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar

            if let errorMessage = viewModel.errorMessage {
                errorBanner(errorMessage)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if viewModel.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(
                                    message: message,
                                    isStreaming: viewModel.isGenerating
                                        && message.role == .assistant
                                        && message.id == viewModel.messages.last?.id
                                )
                                .id(message.id)
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.scrollVersion) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            ComposerBar(
                text: $draftText,
                canSend: viewModel.canSend,
                isGenerating: viewModel.isGenerating,
                onSend: {
                    let text = draftText
                    draftText = ""
                    viewModel.send(text)
                },
                onStop: {
                    viewModel.stop()
                }
            )
        }
        .navigationTitle(viewModel.conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.startNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Percakapan baru")
                .disabled(viewModel.isGenerating)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    systemPromptDraft = viewModel.systemPrompt
                    showingSystemPrompt = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("System prompt")
            }
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [ggufType],
            allowsMultipleSelection: false
        ) { result in
            viewModel.importPickedModel(result: result)
        }
        .sheet(isPresented: $showingSystemPrompt) {
            systemPromptSheet
        }
        .task {
            await viewModel.loadModelIfNeeded()
        }
    }

    // MARK: - Subview

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isModelLoaded ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let tokPerSec = viewModel.tokPerSec, viewModel.isGenerating {
                Text(String(format: "%.1f tok/detik", tokPerSec))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.footnote)
            Spacer()
            Button("Tutup") {
                viewModel.dismissError()
            }
            .font(.footnote)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
        .foregroundStyle(.red)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mulai mengobrol")
                .font(.title3)
                .bold()
            if viewModel.isLoadingModel {
                ProgressView("Memuat model…")
            } else if viewModel.isModelLoaded {
                Text("Model sudah siap. Tulis pesan di bawah — jawaban di-generate sepenuhnya offline di perangkat ini.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let modelName = viewModel.modelName {
                    Text("Model: \(modelName) • n_ctx \(viewModel.actualNCtx)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Belum ada model .gguf di perangkat. Impor satu file model dari Files untuk mulai.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button("Pilih Model (.gguf)") {
                    showingPicker = true
                }
                .buttonStyle(.borderedProminent)
                Button("Coba Muat Lagi") {
                    Task { await viewModel.loadModel() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private var systemPromptSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("System prompt dipakai untuk jawaban berikutnya. Perubahan tersimpan dan langsung berlaku — tidak perlu load ulang model.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $systemPromptDraft)
                    .font(.body)
                    .padding(8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding()
            .navigationTitle("System Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Batal") {
                        showingSystemPrompt = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan") {
                        viewModel.setSystemPrompt(systemPromptDraft)
                        showingSystemPrompt = false
                    }
                    .disabled(systemPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var ggufType: UTType {
        UTType(filenameExtension: "gguf") ?? .data
    }
}
