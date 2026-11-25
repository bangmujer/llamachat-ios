import Foundation

/// Deskripsi satu file model GGUF di disk.
///
/// `nLayer`, `nEmbd`, `nHead`, `nHeadKV`, `nCtxTrain`, dan `chatTemplate`
/// hanya terisi SETELAH probe metadata berhasil (lihat `LlamaEngine`).
/// Sebelum itu nilainya nil — jangan pakai angka-angka itu untuk estimasi
/// memori sebelum probe.
public struct ModelDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileURL: URL
    public let fileName: String
    public let fileSizeBytes: Int64

    public var nParams: UInt64?
    public var nLayer: Int32?
    public var nEmbd: Int32?
    public var nHead: Int32?
    public var nHeadKV: Int32?
    public var nCtxTrain: Int32?
    /// Template chat mentah dari metadata GGUF, kalau ada.
    /// String Jinja; dirender oleh llama.cpp lewat `llama_chat_apply_template`
    /// di Fase C, bukan di-parse manual di sini.
    public var chatTemplate: String?

    public init(fileURL: URL, fileSizeBytes: Int64) {
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.id = fileURL.lastPathComponent
        self.fileSizeBytes = fileSizeBytes
    }

    public var displaySize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }
}
