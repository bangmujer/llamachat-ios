import Foundation

/// Jenis lampiran pada pesan (Build 2).
public enum AttachmentKind: String, Codable, Sendable {
    /// Gambar dari galeri; teks hasil OCR disimpan di `extractedText`.
    case image
    /// File teks/PDF; isi yang diekstrak disimpan di `extractedText`.
    case file
    /// Voice note yang direkam di app; transkripsi jadi isi pesan,
    /// `extractedText` menyimpan transkripsinya juga untuk arsip.
    case audio
}

/// Satu lampiran pada `ChatMessage` (Build 2).
///
/// File aslinya disimpan di `Application Support/Attachments/` dengan
/// nama `storedFileName` (unik per id); `fileName` adalah nama yang
/// ditampilkan. `extractedText` adalah teks yang dibaca dari lampiran
/// (OCR untuk gambar, isi teks untuk file) dan dipakai sebagai konteks
/// prompt — model teks tidak bisa "melihat" gambar atau file.
/// `isProcessing` hanya state UI sementara (OCR/ekstraksi berjalan);
/// selalu di-reset ke false saat pesan dipulihkan dari SwiftData.
public struct ChatAttachment: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let kind: AttachmentKind
    public let fileName: String
    public let storedFileName: String
    public let byteCount: Int
    /// Durasi detik, hanya bermakna untuk `.audio`.
    public let duration: TimeInterval
    public var extractedText: String
    public var isProcessing: Bool

    public init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        fileName: String,
        storedFileName: String,
        byteCount: Int,
        duration: TimeInterval = 0,
        extractedText: String = "",
        isProcessing: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.storedFileName = storedFileName
        self.byteCount = byteCount
        self.duration = duration
        self.extractedText = extractedText
        self.isProcessing = isProcessing
    }

    public var fileURL: URL {
        (try? AttachmentStore.attachmentsDirectory())?
            .appendingPathComponent(storedFileName)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(storedFileName)
    }

    /// Blok konteks yang ditempel ke isi pesan pengguna saat prompt
    /// di-render (lihat `ChatViewModel`). Hanya teks hasil ekstraksi
    /// yang dikirim ke model; file aslinya tidak pernah dibaca model.
    public static func promptContext(for attachments: [ChatAttachment]) -> String {
        var blocks: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                let ocr = attachment.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(
                    "[Lampiran gambar: \(attachment.fileName)]\nTeks yang terbaca dari gambar (OCR):\n\(ocr.isEmpty ? "(tidak ada teks yang terbaca)" : ocr)"
                )
            case .file:
                let body = attachment.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(
                    "[Lampiran file: \(attachment.fileName)]\nIsi file:\n\(body.isEmpty ? "(file kosong atau tidak bisa dibaca)" : body)"
                )
            case .audio:
                blocks.append(
                    "[Voice note terlampir, durasi \(Int(attachment.duration.rounded())) detik. Transkripsinya adalah isi pesan ini.]"
                )
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// Penyimpanan file lampiran di sandbox app.
public enum AttachmentStore {
    public static func attachmentsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func save(
        data: Data,
        kind: AttachmentKind,
        fileName: String,
        duration: TimeInterval = 0,
        extractedText: String = ""
    ) throws -> ChatAttachment {
        let id = UUID()
        let ext = (fileName as NSString).pathExtension
        let storedFileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let url = try attachmentsDirectory().appendingPathComponent(storedFileName)
        try data.write(to: url, options: .atomic)
        excludeFromBackup(url)
        return ChatAttachment(
            id: id,
            kind: kind,
            fileName: fileName,
            storedFileName: storedFileName,
            byteCount: data.count,
            duration: duration,
            extractedText: extractedText
        )
    }

    public static func saveImage(data: Data, fileName: String) throws -> ChatAttachment {
        try save(data: data, kind: .image, fileName: fileName)
    }

    public static func saveFile(data: Data, fileName: String) throws -> ChatAttachment {
        try save(data: data, kind: .file, fileName: fileName)
    }

    public static func saveAudio(data: Data, duration: TimeInterval, transcription: String) throws -> ChatAttachment {
        try save(data: data, kind: .audio, fileName: "Voice note.m4a", duration: duration, extractedText: transcription)
    }

    public static func delete(_ attachment: ChatAttachment) {
        try? FileManager.default.removeItem(at: attachment.fileURL)
    }

    public static func displaySize(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}
