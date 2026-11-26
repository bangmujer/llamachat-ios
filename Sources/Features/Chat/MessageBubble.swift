import SwiftUI

/// Satu bubble pesan.
///
/// - Pesan pengguna: rata kanan, latar aksen.
/// - Pesan asisten: rata kiri, latar sekunder, teks bisa dipilih
///   (seleksi = cara menyalin; menu konteks Salin/Ubah/Buat ulang
///   datang di Fase 2 dan dipasang di `ChatView`).
/// - Blok penalaran `<think>` model TIDAK ditampilkan mentah: ia masuk
///   ke bagian "Proses berpikir" yang terlipat secara default dan bisa
///   dibuka dengan ketukan. Selama streaming masih berpikir, labelnya
///   "Berpikir…". Ini tampilan sementara — redesign UI/UX menyeluruh
///   baru dikerjakan setelah semua fase selesai, sesuai arahan pengguna.
/// - Jawaban asisten dirender sebagai Markdown blok oleh
///   `MarkdownContentView` (heading, daftar, blok kode + tombol Salin,
///   pemisah, kutipan, plus sintaks inline). Parsernya toleran
///   terhadap fence yang belum tertutup saat streaming.
/// - `isStreaming`: tampilkan kursor "▍" di ujung jawaban yang sedang
///   mengalir; hilang begitu generation selesai.
struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming: Bool = false
    /// Lipat/buka pesan panjang (tombol "Lihat selengkapnya").
    /// Per bubble, keyed oleh identitas view dari `ForEach` + `.id`.
    @State private var expanded = false
    /// Pembaca TTS bersama (Build 2): tombol speaker di bawah jawaban
    /// asisten membacakan/menghentikan pembacaan jawaban ini.
    @ObservedObject private var speechReader = SpeechReader.shared

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "Kamu" : "Asisten")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !message.attachments.isEmpty {
                    MessageAttachmentsView(attachments: message.attachments)
                }

                if message.role == .assistant {
                    assistantContent
                } else if message.content.count > Self.collapseThreshold {
                    // Pesan pengguna yang panjang: lipat dengan tombol
                    // "Lihat selengkapnya" / "Tutup selengkapnya".
                    VStack(alignment: .leading, spacing: 4) {
                        Text(expanded ? message.content : Self.collapsed(message.content))
                            .font(.body)
                            .textSelection(.enabled)
                        expandButton
                    }
                } else {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.85)
                    : Color.secondary.opacity(0.12)
            )
            .foregroundStyle(message.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
    }

    private var assistantContent: some View {
        let parts = ThinkBlock.split(message.content)
        let thinking = (parts.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let showThinking = !thinking.isEmpty
        let showAnswer = !parts.answer.isEmpty || (!parts.isThinkingOpen && !isStreaming)

        return Group {
            if showThinking {
                DisclosureGroup {
                    Text(thinking + (isStreaming && parts.isThinkingOpen ? " ▍" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label(
                        parts.isThinkingOpen ? "Berpikir…" : "Proses berpikir",
                        systemImage: "brain"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if showAnswer {
                // Pesan panjang dilipat saat tidak streaming; tombol di
                // bawah untuk membuka/menutup selengkapnya. Saat
                // streaming selalu tampil penuh supaya teks yang
                // mengalir tidak melompat-lompat.
                let needsCollapse = !isStreaming && parts.answer.count > Self.collapseThreshold
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownContentView(
                        text: needsCollapse && !expanded ? Self.collapsed(parts.answer) : parts.answer,
                        isStreaming: isStreaming
                    )
                    if needsCollapse {
                        expandButton
                    }
                }
                // Tombol dengarkan (Build 2): bacakan jawaban dengan
                // TTS. Hanya setelah generation selesai, supaya yang
                // dibacakan adalah jawaban utuh.
                if !isStreaming, !parts.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    listenButton(answer: parts.answer)
                }
            } else if isStreaming {
                // Masih di dalam blok think dan jawaban belum mulai:
                // jangan tampilkan bubble kosong, label "Berpikir…"
                // di atas sudah menjelaskan state-nya.
                EmptyView()
            }
        }
    }

    // MARK: - Lipat pesan panjang

    /// Ambang lipat: pesan di atas ini dilipat dan butuh ketukan
    /// "Lihat selengkapnya" untuk membaca sisanya.
    private static let collapseThreshold = 600

    private var expandButton: some View {
        Button(expanded ? "Tutup selengkapnya" : "Lihat selengkapnya") {
            expanded.toggle()
            Haptics.light()
        }
        .font(.footnote)
    }

    /// Tombol speaker (Build 2): ketuk untuk membacakan jawaban,
    /// ketuk lagi untuk berhenti. Menunjukkan state aktif kalau pesan
    /// ini yang sedang dibacakan.
    private func listenButton(answer: String) -> some View {
        let isSpeakingThis = speechReader.isSpeaking && speechReader.speakingMessageID == message.id
        return Button {
            speechReader.toggle(answer, messageID: message.id)
        } label: {
            Label(
                isSpeakingThis ? "Berhenti" : "Dengarkan",
                systemImage: isSpeakingThis ? "stop.circle" : "speaker.wave.2"
            )
            .font(.footnote)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// Potong teks ke ambang lipat di batas kata/baris terdekat, tambah
    /// "…", dan tutup fence kode yang terpotong supaya parser Markdown
    /// tidak menganggap sisanya sebagai kode.
    private static func collapsed(_ text: String) -> String {
        let limit = collapseThreshold
        guard text.count > limit else { return text }
        var end = text.index(text.startIndex, offsetBy: limit)
        let prefix = text[..<end]
        if let lastBreak = prefix.lastIndex(where: { $0 == "\n" || $0 == " " }),
           prefix.distance(from: prefix.startIndex, to: lastBreak) > limit - 120 {
            end = lastBreak
        }
        var result = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        if result.components(separatedBy: "```").count % 2 == 0 {
            result += "\n```"
        }
        return result
    }
}
