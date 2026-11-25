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

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
