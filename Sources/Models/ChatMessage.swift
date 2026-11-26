import Foundation

/// Satu pesan dalam percakapan.
///
/// Fase A: struct polos. Persistensi SwiftData datang di Fase D; engine dan
/// template tidak boleh bergantung pada persistence di fase ini, supaya
/// konversi ke `@Model` nanti tidak mengubah kode inference.
public struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String
    /// Lampiran Build 2 (gambar/file/voice note). Kosong untuk pesan
    /// asisten dan pesan lama sebelum Build 2. Teks hasil ekstraksi
    /// lampiran TIDAK ada di `content`; ia ditempel ke prompt saat
    /// generation (lihat `ChatAttachment.promptContext`).
    public let attachments: [ChatAttachment]

    public init(id: UUID = UUID(), role: Role, content: String, attachments: [ChatAttachment] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
    }
}
