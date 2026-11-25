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
/// - Jawaban asisten dirender Markdown ringan Fase 2 (hanya sintaks
///   inline: tebal, miring, kode, coret, tautan).
/// - `isStreaming`: tampilkan kursor "▍" di ujung jawaban yang sedang
///   mengalir; hilang begitu generation selesai.
struct MessageBubble: View {
    let message: ChatMessage
    var isStreaming: Bool = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "Kamu" : "Asisten")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if message.role == .assistant {
                    assistantContent
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
                Text(markdownText(answer: parts.answer, isStreaming: isStreaming))
                    .textSelection(.enabled)
            } else if isStreaming {
                // Masih di dalam blok think dan jawaban belum mulai:
                // jangan tampilkan bubble kosong, label "Berpikir…"
                // di atas sudah menjelaskan state-nya.
                EmptyView()
            }
        }
    }

    /// Markdown ringan Fase 2: hanya sintaks inline (tebal, miring,
    /// kode inline, coret, tautan). Kalau parsing gagal — wajar saat
    /// streaming karena penanda belum tertutup — jatuh ke teks polos.
    /// Kursor streaming "▍" ditambahkan SETELAH parsing supaya tidak
    /// merusak sintaks Markdown.
    private func markdownText(answer: String, isStreaming: Bool) -> AttributedString {
        let parsed = (try? AttributedString(
            markdown: answer,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(answer)
        guard isStreaming else { return parsed }
        var withCursor = parsed
        withCursor.append(AttributedString(" ▍"))
        return withCursor
    }
}
