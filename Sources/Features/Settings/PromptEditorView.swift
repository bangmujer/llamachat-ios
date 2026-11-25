import SwiftUI
import UniformTypeIdentifiers

/// Editor system prompt mandiri, dipakai dari Settings dan (nanti)
/// dari sheet cepat. Simpan hanya lewat tombol Simpan; Batal tidak
/// mengubah apa pun. Teks kosong ditolak — system prompt kosong
/// berarti generation tanpa instruksi system sama sekali, dan itu
/// harus keputusan eksplisit, bukan kecelakaan ketik.
public struct PromptEditorView: View {
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
                .navigationTitle("System Prompt")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Batal") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Simpan") {
                            onSave(draft)
                            dismiss()
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            Text("Berlaku untuk balasan berikutnya. Tidak perlu load ulang model.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }
}
