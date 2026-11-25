import Foundation

/// Percakapan: urutan pesan + metadata ringan.
///
/// Fase A: struct polos, disimpan di memori saja oleh harness Fase A.
/// Fase D mengubah tipe ini menjadi SwiftData `@Model` dan menambahkan
/// penyimpanan. Isi (`messages`) tidak berubah bentuknya.
public struct Conversation: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "Percakapan baru",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
