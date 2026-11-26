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
    /// Lampiran Build 2, di-encode sebagai JSON `[ChatAttachment]`.
    /// Nil = pesan tanpa lampiran (termasuk semua pesan lama sebelum
    /// Build 2). File lampiran sendiri hidup di
    /// `Application Support/Attachments/`, bukan di database.
    public var attachmentsData: Data?

    public init(
        id: UUID = UUID(),
        role: ChatMessage.Role,
        content: String,
        createdAt: Date = Date(),
        sortIndex: Int = 0,
        conversation: Conversation? = nil,
        attachmentsData: Data? = nil
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.conversation = conversation
        self.attachmentsData = attachmentsData
    }

    public var role: ChatMessage.Role {
        ChatMessage.Role(rawValue: roleRaw) ?? .user
    }

    public var chatMessage: ChatMessage {
        var attachments: [ChatAttachment] = []
        if let data = attachmentsData,
           let decoded = try? JSONDecoder().decode([ChatAttachment].self, from: data) {
            // State proses sementara tidak boleh bertahan setelah
            // restore: ekstraksi sudah selesai atau tidak pernah jalan.
            attachments = decoded.map { attachment in
                var copy = attachment
                copy.isProcessing = false
                return copy
            }
        }
        return ChatMessage(id: id, role: role, content: content, attachments: attachments)
    }
}
