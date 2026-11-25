import SwiftUI

/// Editor pesan pengguna (Fase 2: Ubah & kirim ulang).
///
/// Sheet mandiri: Simpan hanya lewat tombol Simpan; Batal tidak
/// mengubah apa pun. Simpan dengan teks kosong dinonaktifkan — pesan
/// kosong tidak bisa dikirim ulang. ViewModel yang memanggil
/// (`editUserMessage`) membuang semua pesan setelah pesan yang diubah
/// dan menjalankan generation ulang.
public struct EditMessageView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String
    private let onSave: (String) -> Void

    public init(initialText: String, onSave: @escaping (String) -> Void) {
        self._draft = State(initialValue: initialText)
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .padding()
                .navigationTitle("Ubah Pesan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Batal") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Simpan & Kirim Ulang") {
                            onSave(draft)
                            dismiss()
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            Text("Pesan setelah pesan ini akan dibuang dan jawaban dibuat ulang.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }
}
