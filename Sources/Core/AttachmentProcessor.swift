import Foundation
import PDFKit
import Vision
import ZIPFoundation

/// Ekstraksi teks dari lampiran (Build 2), sepenuhnya on-device.
///
/// - Gambar: OCR Vision (`VNRecognizeTextRequest`, bahasa Indonesia +
///   Inggris, level akurat). Tidak ada network call.
/// - File `.pdf`: teks per halaman via PDFKit.
/// - File teks lain (`.txt`/`.md`/`.json`/`.csv`): dibaca sebagai UTF-8.
/// - Arsip `.zip`: dibaca entrinya dengan ZIPFoundation (stored +
///   deflate); semua file teks/source code digabung dengan header
///   nama file, dibatasi totalnya supaya tidak membanjiri konteks.
/// Semua hasil dibatasi supaya tidak membanjiri konteks model.
public enum AttachmentProcessor {
    private static let maxExtractedCharacters = 8_000
    private static let maxOCRCharacters = 4_000
    /// Batas per file di dalam ZIP dan total data yang dibaca dari
    /// arsip (pelindung zip bomb: arsip kecil bisa mengembang besar).
    private static let maxZipEntryBytes = 256_000
    private static let maxZipFiles = 100

    /// Ekstensi yang dianggap teks/source code di dalam ZIP. File
    /// biner (gambar, audio, executable, dll) dilewati — model teks
    /// tidak bisa memakainya, dan membacanya hanya mengotori konteks.
    private static let zipTextExtensions: Set<String> = [
        "swift", "kt", "kts", "java", "c", "h", "cpp", "cc", "cxx", "hpp",
        "m", "mm", "cs", "go", "rs", "py", "rb", "js", "jsx", "ts", "tsx",
        "html", "htm", "css", "scss", "xml", "json", "plist", "yaml", "yml",
        "toml", "gradle", "md", "markdown", "txt", "csv", "sh", "sql",
        "php", "lua", "dart", "vue", "svelte", "properties", "env",
        "gitignore", "dockerignore",
    ]

    public static func extractText(for attachment: ChatAttachment) async -> String {
        let url = attachment.fileURL
        guard let data = try? Data(contentsOf: url) else { return "" }
        switch attachment.kind {
        case .image:
            return await ocrText(from: data)
        case .file:
            return extractedFileText(data: data, fileName: attachment.fileName)
        case .audio:
            return attachment.extractedText
        }
    }

    /// OCR gambar. `VNImageRequestHandler.perform` sinkron, jadi
    /// dijalankan di antrean latar; hasil dibaca langsung dari request
    /// setelah perform kembali (tidak bergantung pada completion
    /// handler yang antreannya tidak dijamin).
    public static func ocrText(from imageData: Data) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["id-ID", "en-US"]
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(data: imageData, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    let text = lines.joined(separator: "\n")
                    continuation.resume(returning: String(text.prefix(maxOCRCharacters)))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    private static func extractedFileText(data: Data, fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext == "zip" {
            return extractZipText(data: data, fileName: fileName)
        }
        if ext == "pdf" {
            guard let document = PDFDocument(data: data) else { return "" }
            var text = ""
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index),
                      let pageString = page.string else { continue }
                text += pageString
                if text.count >= maxExtractedCharacters { break }
                text += "\n"
            }
            return String(text.prefix(maxExtractedCharacters))
        }
        let text = String(decoding: data, as: UTF8.self)
        return String(text.prefix(maxExtractedCharacters))
    }

    // MARK: - Arsip ZIP

    /// Baca arsip ZIP dan gabungkan semua file teks/source code di
    /// dalamnya menjadi satu teks dengan header nama file per entri.
    ///
    /// Pengaman: entri direktori/symlink dilewati, path `..`/absolut
    /// ditolak (tidak boleh keluar dari folder temp), entri
    /// `__MACOSX`/`.DS_Store`/`.git` dilewati, ukuran per entri dan
    /// jumlah file dibatasi, dan total teks dibatasi. Arsip yang bukan
    /// ZIP valid menghasilkan daftar kosong + pesan jujur.
    private static func extractZipText(data: Data, fileName: String) -> String {
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zip-extract-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDir) }
            let zipURL = workDir.appendingPathComponent("archive.zip")
            try data.write(to: zipURL, options: .atomic)
            let archive = try Archive(url: zipURL, accessMode: .read)

            var textPaths: [String] = []
            var sections: [(path: String, content: String)] = []
            var totalBudget = maxExtractedCharacters
            for entry in archive {
                guard textPaths.count < maxZipFiles else { break }
                guard entry.type == .file else { continue }
                let path = entry.path
                // Tolak path yang mencoba keluar dari folder kerja.
                guard !path.hasPrefix("/"), !path.contains("..") else { continue }
                let baseName = (path as NSString).lastPathComponent
                guard !path.hasPrefix("__MACOSX/"), baseName != ".DS_Store",
                      !path.hasPrefix(".git/") else { continue }
                let ext = (path as NSString).pathExtension.lowercased()
                let isText = zipTextExtensions.contains(ext)
                    || zipTextExtensions.contains(baseName.lowercased())
                guard isText else { continue }
                guard Int(entry.uncompressedSize) <= maxZipEntryBytes else { continue }
                textPaths.append(path)
                let dest = workDir.appendingPathComponent("entry-\(sections.count)")
                _ = try archive.extract(entry, to: dest)
                defer { try? FileManager.default.removeItem(at: dest) }
                guard let entryData = try? Data(contentsOf: dest) else { continue }
                let content = String(decoding: entryData, as: UTF8.self)
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let taken = String(content.prefix(totalBudget))
                sections.append((path: path, content: taken))
                totalBudget -= taken.count
                if totalBudget <= 0 { break }
            }

            if textPaths.isEmpty {
                return "Arsip ZIP '\(fileName)' tidak berisi file teks/source code yang bisa dibaca."
            }
            var output = "Arsip ZIP '\(fileName)' — \(textPaths.count) file teks ditemukan:\n"
            output += textPaths.map { "- \($0)" }.joined(separator: "\n")
            output += "\n"
            for section in sections {
                output += "\n=== \(section.path) ===\n\(section.content)\n"
            }
            if totalBudget <= 0 {
                output += "\n... (isi dipotong karena melebihi batas konteks)"
            }
            return String(output.prefix(maxExtractedCharacters + 2_000))
        } catch {
            return "Arsip ZIP '\(fileName)' tidak bisa dibaca (\(error.localizedDescription))."
        }
    }
}
