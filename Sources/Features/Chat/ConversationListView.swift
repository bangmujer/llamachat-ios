import SwiftUI
import SwiftData

/// Daftar percakapan tersimpan (Fase D), tampil sebagai sheet dari
/// `ChatView`.
///
/// - Diurutkan dari yang terakhir diubah. Ketuk satu baris untuk
///   membukanya di `ChatView` yang sama (model yang ter-load tidak
///   di-unload saat ganti percakapan).
/// - Geser untuk menghapus; menghapus percakapan yang sedang dibuka
///   juga melupakan state-nya di ViewModel supaya tidak tersimpan
///   kembali diam-diam.
/// - Sengaja BUKAN redesign navigasi menyeluruh (tidak ada sidebar /
///   NavigationSplitView): redesign UI/UX menyeluruh baru dikerjakan
///   setelah semua fase selesai, sesuai arahan pengguna.
struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ChatViewModel

    @Query(sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "Belum ada percakapan",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Percakapan tersimpan otomatis setelah pesan pertama terkirim.")
                    )
                } else {
                    List {
                        ForEach(conversations) { conversation in
                            Button {
                                viewModel.loadConversation(conversation)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title)
                                        .lineLimit(1)
                                    Text("\(conversation.messages.count) pesan • \(conversation.updatedAt, format: .dateTime.day().month().hour().minute())")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Percakapan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tutup") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.startNewChat()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Percakapan baru")
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            if conversation.id == viewModel.currentConversationID {
                viewModel.forgetCurrentConversation()
            }
            modelContext.delete(conversation)
        }
        try? modelContext.save()
    }
}
