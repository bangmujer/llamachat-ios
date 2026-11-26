import Foundation
import PDFKit
import Vision

/// Ekstraksi teks dari lampiran (Build 2), sepenuhnya on-device.
///
/// - Gambar: OCR Vision (`VNRecognizeTextRequest`, bahasa Indonesia +
///   Inggris, level akurat). Tidak ada network call.
/// - File `.pdf`: teks per halaman via PDFKit.
/// - File teks lain (`.txt`/`.md`/`.json`/`.csv`): dibaca sebagai UTF-8.
/// Semua hasil dibatasi supaya tidak membanjiri konteks model.
public enum AttachmentProcessor {
    private static let maxExtractedCharacters = 8_000
    private static let maxOCRCharacters = 4_000

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
}
