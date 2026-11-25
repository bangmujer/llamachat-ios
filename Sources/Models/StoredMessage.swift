import Foundation
import SwiftData

/// Satu pesan tersimpan (SwiftData, Fase D).
///
/// Pasangan persistensi dari `ChatMessage`: `role` disimpan sebagai
/// string mentah (`ChatMessage.Role.rawValue`) supaya skema tetap
/// sederhana dan tidak bergantung pada enum Swift di database.
/// `content` menyimpan isi mentah lengkap, TERMASUK blok `<think>`
/// kalau ada — pemisahan think untuk tampilan/prompt tetap terjadi di
/// `ThinkBlock`, bukan di sini, supaya tidak ada informasi yang hilang
/// saat disimpan.
@Model
public final class StoredMessage {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    public var content: String
    public var createdAt: Date
    /// Posisi pesan di dalam percakapannya. Ditulis ulang setiap kali
    /// percakapan disimpan, mengikuti urutan array `messages` di memori.
    public var sortIndex: Int
    public var conversation: Conversation?

    public init(
        id: UUID = UUID(),
        role: ChatMessage.Role,
        content: String,
        createdAt: Date = Date(),
        sortIndex: Int = 0,
        conversation: Conversation? = nil
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.conversation = conversation
    }

    public var role: ChatMessage.Role {
        ChatMessage.Role(rawValue: roleRaw) ?? .user
    }

    public var chatMessage: ChatMessage {
        ChatMessage(id: id, role: role, content: content)
    }
}
