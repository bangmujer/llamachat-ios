import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Baris penulisan pesan di bawah chat (Build 2 menambahkan lampiran
/// dan voice note).
///
/// - Saat tidak generating: tombol kirim (panah), aktif kalau teks
///   tidak kosong ATAU ada lampiran tertunda.
/// - Saat generating: tombol yang sama berubah menjadi tombol Stop
///   merah — menekan Stop membatalkan generation, bukan sekadar
///   menyembunyikan teks.
/// - TextField multiline (axis vertical) supaya pesan panjang tetap
///   bisa dibaca sebelum dikirim.
/// - Tombol klip membuka menu lampiran (Foto / File); tombol mic
///   mulai/berhenti merekam voice note. Selama merekam, tampil
///   indikator durasi; selama transkripsi, tampil spinner.
/// - Chip lampiran tertunda tampil di atas baris tulis; ketuk `x`
///   untuk membatalkan lampiran.
/// - Picker foto/file tinggal di view ini (presentation modifier
///   sendiri, terpisah dari fileImporter model .gguf di `ChatView`);
///   hasilnya dilaporkan ke `ChatView` lewat callback untuk diproses
///   (OCR/ekstraksi) di sana.
struct ComposerBar: View {
    @Binding var text: String
    var canSend: Bool
    var isGenerating: Bool
    var pendingAttachments: [ChatAttachment]
    var isRecording: Bool
    var recordingElapsed: TimeInterval
    var isTranscribing: Bool
    var onRemoveAttachment: (ChatAttachment) -> Void
    var onPhotoPicked: (PhotosPickerItem) -> Void
    var onFilesPicked: (Result<[URL], Error>) -> Void
    var onMicTap: () -> Void
    var onSend: () -> Void
    var onStop: () -> Void

    @State private var showingAttachMenu = false
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var photoItem: PhotosPickerItem?

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sendEnabled: Bool {
        canSend && (!trimmedText.isEmpty || !pendingAttachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 8) {
            if !pendingAttachments.isEmpty {
                PendingAttachmentsView(attachments: pendingAttachments, onRemove: onRemoveAttachment)
            }

            if isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("Merekam \(Self.formatDuration(recordingElapsed)) — ketuk mic untuk berhenti")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showingAttachMenu = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .disabled(isGenerating || isRecording || isTranscribing)
                .accessibilityLabel("Lampiran")

                Button {
                    onMicTap()
                } label: {
                    if isTranscribing {
                        ProgressView()
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.body)
                            .frame(width: 36, height: 36)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .red : .secondary)
                .disabled(isGenerating || isTranscribing)
                .accessibilityLabel(isRecording ? "Berhenti merekam" : "Rekam voice note")

                TextField("Tulis pesan…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onSubmit {
                        if sendEnabled {
                            onSend()
                        }
                    }

                Button {
                    if isGenerating {
                        onStop()
                    } else {
                        onSend()
                    }
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.body.bold())
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(isGenerating ? .red : .accentColor)
                .disabled(isGenerating ? false : !sendEnabled)
                .accessibilityLabel(isGenerating ? "Stop" : "Kirim")
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog("Lampiran", isPresented: $showingAttachMenu) {
            Button("Foto dari Galeri") {
                showingPhotoPicker = true
            }
            Button("File (teks / PDF / ZIP)") {
                showingFileImporter = true
            }
            Button("Batal", role: .cancel) {}
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem?.itemIdentifier) { _, _ in
            guard let item = photoItem else { return }
            photoItem = nil
            onPhotoPicked(item)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: Self.attachmentTypes,
            allowsMultipleSelection: false,
            onCompletion: onFilesPicked
        )
    }

    /// Tipe file yang diterima sebagai lampiran: teks, Markdown, JSON,
    /// CSV, PDF, dan arsip ZIP. Validasi isi + batas ukuran dilakukan di
    /// `ChatView` saat file dibaca.
    private static var attachmentTypes: [UTType] {
        [
            UTType.plainText,
            UTType.pdf,
            UTType.json,
            UTType.commaSeparatedText,
            UTType(filenameExtension: "md") ?? UTType.plainText,
            UTType(filenameExtension: "markdown") ?? UTType.plainText,
            UTType(filenameExtension: "zip") ?? UTType.data,
        ]
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
