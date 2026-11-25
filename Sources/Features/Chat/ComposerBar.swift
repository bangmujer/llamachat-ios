import SwiftUI

/// Baris penulisan pesan di bawah chat.
///
/// - Saat tidak generating: tombol kirim (panah), aktif hanya kalau
///   `canSend` dan teks tidak kosong.
/// - Saat generating: tombol yang sama berubah menjadi tombol Stop
///   merah — menekan Stop membatalkan generation, bukan sekadar
///   menyembunyikan teks.
/// - TextField multiline (axis vertical) supaya pesan panjang tetap
///   bisa dibaca sebelum dikirim.
struct ComposerBar: View {
    @Binding var text: String
    var canSend: Bool
    var isGenerating: Bool
    var onSend: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Tulis pesan…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .onSubmit {
                    if canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            .disabled(isGenerating ? false : !(canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .accessibilityLabel(isGenerating ? "Stop" : "Kirim")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
