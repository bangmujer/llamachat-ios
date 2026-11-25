import Foundation
import SwiftData

/// Percakapan tersimpan (SwiftData, Fase D).
///
/// Menggantikan struct polos Fase A: satu percakapan kini hidup di
/// database SwiftData dan bertahan melewati restart app. `ChatMessage`
/// (struct) TETAP menjadi tipe yang dipakai engine dan template chat —
/// ViewModel memetakan bolak-balik antara entity ini dan `ChatMessage`,
/// supaya kode inference tidak pernah bergantung pada persistence.
///
/// Urutan pesan dijamin oleh `sortIndex` pada `StoredMessage`, bukan
/// oleh `createdAt`: dua pesan yang dibuat dalam milidetik yang sama
/// tetap punya urutan yang pasti. `title` diambil dari pesan pengguna
/// pertama (40 karakter pertama), sama seperti judul di memori Fase B.
@Model
public final class Conversation {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    public var messages: [StoredMessage] = []

    public init(
        id: UUID = UUID(),
        title: String = "Percakapan baru",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Pesan-pesan dalam urutan percakapan.
    public var orderedMessages: [StoredMessage] {
        messages.sorted { $0.sortIndex < $1.sortIndex }
    }
}
