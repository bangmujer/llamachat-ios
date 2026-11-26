import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Chat UI Fase B/D: satu percakapan di layar, riwayat tersimpan di
/// SwiftData dan bisa dibuka lewat daftar percakapan (sheet).
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
/// - Persistensi percakapan (SwiftData, multi-conversation) aktif mulai
///   Fase D: percakapan terakhir yang diubah dipulihkan saat app dibuka,
///   tombol daftar percakapan membuka sheet pilih/hapus, dan tombol
///   Percakapan Baru memulai percakapan kosong baru.
struct ChatView: View {
    let engine: LlamaEngine

    @StateObject private var viewModel: ChatViewModel
    @StateObject private var voiceRecorder = VoiceRecorder()
    @State private var draftText = ""
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingConversations = false
    /// Lampiran Build 2 yang menunggu dikirim bersama pesan berikutnya.
    @State private var pendingAttachments: [ChatAttachment] = []
    /// Mode suara (Build 2): voice note langsung dikirim + jawaban
    /// dibacakan otomatis. Dibaca di sini untuk alur kirim otomatis;
    /// nilainya diubah di Settings → Suara.
    @AppStorage("llamachat.voiceModeEnabled") private var voiceModeEnabled = false
    /// Pesan pengguna yang sedang diubah lewat sheet editor (Fase 2).
    @State private var editingMessage: ChatMessage?

    init(engine: LlamaEngine, modelContext: ModelContext) {
        self.engine = engine
        _viewModel = StateObject(wrappedValue: ChatViewModel(engine: engine, modelContext: modelContext))
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
                                .contextMenu {
                                    messageContextMenu(for: message)
                                }
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                // Ketuk area pesan (di luar keyboard) = keyboard turun.
                // Sengaja hanya di ScrollView, BUKAN di VStack luar:
                // gesture di luar akan ikut bereaksi saat TextField
                // composer diketuk dan keyboard langsung tertutup lagi.
                // Scroll juga menurunkan keyboard secara interaktif.
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    hideKeyboard()
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
                pendingAttachments: pendingAttachments,
                isRecording: voiceRecorder.isRecording,
                recordingElapsed: voiceRecorder.elapsed,
                isTranscribing: voiceRecorder.isTranscribing,
                onRemoveAttachment: removePendingAttachment,
                onPhotoPicked: handlePhotoItem,
                onFilesPicked: handleAttachmentFiles,
                onMicTap: {
                    if voiceRecorder.isRecording {
                        voiceRecorder.stopAndTranscribe()
                    } else {
                        voiceRecorder.startRecording()
                    }
                },
                onSend: {
                    let text = draftText
                    let attachments = pendingAttachments
                    draftText = ""
                    pendingAttachments = []
                    viewModel.send(text, attachments: attachments)
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
                    showingConversations = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("Daftar percakapan")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    voiceRecorder.cancelRecording()
                    viewModel.startNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Percakapan baru")
                .disabled(viewModel.isGenerating)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Pengaturan")
            }
        }
        .fileImporter(
            isPresented: $showingPicker,
            // HANYA .data (public.data), sengaja tanpa tipe .gguf kustom:
            // pencocokan UTI untuk ekstensi tak dikenal (.gguf) tidak
            // bisa diandalkan — file bisa tetap nonaktif di picker kalau
            // UTI dinamis yang dihitung picker tidak cocok dengan tipe
            // yang dideklarasikan app. Dengan .data semua file bisa
            // dipilih; gerbang sebenarnya adalah validasi magic GGUF
            // di `importPickedModel`, bukan filter picker.
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            viewModel.importPickedModel(result: result)
        }
        .onOpenURL { url in
            // File .gguf yang dibuka lewat "Buka di LlamaChat" dari
            // Files/share sheet mendarat sebagai URL Inbox; perlakukan
            // sama seperti hasil picker: salin ke Models/ + validasi.
            viewModel.importPickedModel(result: .success([url]))
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingConversations) {
            ConversationListView(viewModel: viewModel)
        }
        .sheet(item: $editingMessage) { message in
            EditMessageView(initialText: message.content) { newContent in
                viewModel.editUserMessage(id: message.id, newContent: newContent)
            }
        }
        .alert(
            viewModel.pendingToolCall?.title ?? "Jalankan tool?",
            isPresented: Binding(
                get: { viewModel.pendingToolCall != nil },
                set: { if !$0 { viewModel.resolvePendingToolCall(confirmed: false) } }
            ),
            presenting: viewModel.pendingToolCall
        ) { _ in
            Button("Jalankan") {
                viewModel.resolvePendingToolCall(confirmed: true)
            }
            Button("Batal", role: .cancel) {
                viewModel.resolvePendingToolCall(confirmed: false)
            }
        } message: { pending in
            Text(pending.message)
        }
        .task {
            viewModel.restoreLatestConversationIfNeeded()
            await viewModel.loadModelIfNeeded()
        }
        .onChange(of: voiceRecorder.completed) { _, result in
            guard let result else { return }
            handleVoiceRecording(result)
            voiceRecorder.completed = nil
        }
        .alert(
            "Voice note",
            isPresented: Binding(
                get: { voiceRecorder.alertMessage != nil },
                set: { if !$0 { voiceRecorder.alertMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(voiceRecorder.alertMessage ?? "")
        }
    }

    // MARK: - Lampiran & voice note (Build 2)

    private func removePendingAttachment(_ attachment: ChatAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        AttachmentStore.delete(attachment)
    }

    /// Foto dari galeri: simpan sebagai lampiran, lalu jalankan OCR
    /// dan tempel hasilnya ke lampiran yang sama (chip diperbarui).
    private func handlePhotoItem(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else { return }
            let stamp = Self.photoTimestamp()
            guard let attachment = try? AttachmentStore.saveImage(data: data, fileName: "Foto \(stamp).jpg") else { return }
            var pending = attachment
            pending.isProcessing = true
            pendingAttachments.append(pending)
            let text = await AttachmentProcessor.extractText(for: attachment)
            if let index = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) {
                pendingAttachments[index].extractedText = text
                pendingAttachments[index].isProcessing = false
            }
        }
    }

    /// File teks/PDF dari picker: simpan, ekstrak isinya, perbarui chip.
    private func handleAttachmentFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 5_000_000 else { return }
            guard let attachment = try? AttachmentStore.saveFile(data: data, fileName: url.lastPathComponent) else { return }
            var pending = attachment
            pending.isProcessing = true
            pendingAttachments.append(pending)
            let text = await AttachmentProcessor.extractText(for: attachment)
            if let index = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) {
                pendingAttachments[index].extractedText = text
                pendingAttachments[index].isProcessing = false
            }
        }
    }

    /// Voice note selesai ditranskripsi: simpan audio sebagai lampiran,
    /// isi draf dengan transkripsi. Dalam mode suara, langsung kirim
    /// tanpa menunggu pengguna menekan kirim.
    private func handleVoiceRecording(_ result: VoiceRecordingResult) {
        guard let attachment = try? AttachmentStore.saveAudio(
            data: result.audioData,
            duration: result.duration,
            transcription: result.transcription
        ) else { return }
        pendingAttachments.append(attachment)
        if !result.transcription.isEmpty {
            draftText = result.transcription
        }
        guard voiceModeEnabled, !result.transcription.isEmpty else { return }
        let text = draftText
        let attachments = pendingAttachments
        draftText = ""
        pendingAttachments = []
        viewModel.send(text, attachments: attachments)
    }

    private static func photoTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH.mm.ss"
        return formatter.string(from: Date())
    }

    // MARK: - Keyboard

    /// Turunkan keyboard yang sedang aktif, apa pun first responder-nya.
    /// Dipakai tap-di-luar di area pesan; TextField composer tidak punya
    /// @FocusState sendiri, jadi resignFirstResponder lewat UIKit adalah
    /// cara yang tidak mengubah struktur ComposerBar.
    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    // MARK: - Subview

    private var statusBar: some View {
        VStack(spacing: 4) {
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
            // Bar konteks Fase 2: pemakaian konteks generation terakhir
            // (prompt + hasil) terhadap n_ctx. Baru muncul setelah ada
            // generation; sebelum itu tidak ada angka yang bisa
            // ditampilkan dengan jujur.
            if let promptTokens = viewModel.contextPromptTokens,
               let generatedTokens = viewModel.contextGeneratedTokens,
               viewModel.contextLimit > 0 {
                let used = promptTokens + generatedTokens
                HStack(spacing: 8) {
                    ProgressView(value: min(Double(used) / Double(viewModel.contextLimit), 1.0))
                        .progressViewStyle(.linear)
                    Text("Konteks: \(used)/\(viewModel.contextLimit) token")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Menu tekan-lama per pesan (Fase 2). Salin selalu tersedia;
    /// Ubah hanya untuk pesan pengguna, Buat ulang hanya untuk pesan
    /// asisten terakhir — dan semuanya nonaktif saat generation
    /// berjalan, supaya tidak berebut state dengan Task generation.
    @ViewBuilder
    private func messageContextMenu(for message: ChatMessage) -> some View {
        Button {
            UIPasteboard.general.string = copyableText(for: message)
            Haptics.light()
        } label: {
            Label("Salin", systemImage: "doc.on.doc")
        }
        if message.role == .user {
            Button {
                editingMessage = message
            } label: {
                Label("Ubah & kirim ulang", systemImage: "pencil")
            }
            .disabled(viewModel.isGenerating)
        }
        if message.role == .assistant, message.id == viewModel.messages.last?.id {
            Button {
                viewModel.regenerateLastAnswer()
            } label: {
                Label("Buat ulang jawaban", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isGenerating)
        }
    }

    /// Teks yang disalin: jawaban bersih tanpa blok <think> untuk
    /// pesan asisten, isi mentah untuk pesan pengguna.
    private func copyableText(for message: ChatMessage) -> String {
        if message.role == .assistant {
            return ThinkBlock.stripped(message.content)
        }
        return message.content
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

    private var ggufType: UTType {
        UTType.gguf
    }
}
