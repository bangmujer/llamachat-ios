import SwiftUI
import UIKit

/// Rendering Markdown jawaban asisten, tanpa dependensi luar.
///
/// `AttributedString(markdown:)` dengan `.inlineOnly` HANYA mengerti
/// sintaks inline (tebal, miring, kode inline). Heading (`##`),
/// daftar (`-` / `1.`), blok kode (```), pemisah (`---`), dan kutipan
/// (`>`) adalah sintaks BLOK dan tampil mentah kalau hanya
/// mengandalkan parser inline — itu bug yang dilaporkan pengguna.
/// Karena itu jawaban dipecah dulu per blok oleh `MarkdownParser`
/// (state machine per baris, toleran terhadap fence yang belum
/// tertutup saat streaming), lalu tiap blok dirender view-nya
/// sendiri; sintaks inline di dalam blok tetap memakai
/// `AttributedString` inline.
///
/// Blok kode mendapat `CodeBlockView`: header berisi nama bahasa +
/// tombol Salin (menyalin isi kode mentah ke clipboard).
public enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(items: [String])
    case ordered(start: Int, items: [String])
    case code(language: String?, code: String)
    case divider
    case quote(String)
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var orderedStart = 1
        var orderedItems: [String] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines = []
        }
        func flushBullet() {
            guard !bulletItems.isEmpty else { return }
            blocks.append(.bullet(items: bulletItems))
            bulletItems = []
        }
        func flushOrdered() {
            guard !orderedItems.isEmpty else { return }
            blocks.append(.ordered(start: orderedStart, items: orderedItems))
            orderedItems = []
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines = []
        }
        func flushNonCode() {
            flushParagraph(); flushBullet(); flushOrdered(); flushQuote()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines = []; codeLanguage = nil; inCode = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushNonCode()
                inCode = true
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
                continue
            }
            if trimmed.isEmpty {
                flushNonCode()
                continue
            }
            if isDivider(trimmed) {
                flushNonCode()
                blocks.append(.divider)
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushNonCode()
                blocks.append(heading)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushBullet(); flushOrdered()
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                quoteLines.append(content)
                continue
            }
            if let item = parseBullet(trimmed) {
                flushParagraph(); flushOrdered(); flushQuote()
                bulletItems.append(item)
                continue
            }
            if let (number, item) = parseOrdered(trimmed) {
                flushParagraph(); flushBullet(); flushQuote()
                if orderedItems.isEmpty { orderedStart = number }
                orderedItems.append(item)
                continue
            }
            // Baris lanjutan list yang menjorok: gabung ke item terakhir.
            if !bulletItems.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") {
                bulletItems[bulletItems.count - 1] += "\n" + trimmed
                continue
            }
            if !orderedItems.isEmpty, line.hasPrefix(" ") || line.hasPrefix("\t") {
                orderedItems[orderedItems.count - 1] += "\n" + trimmed
                continue
            }
            flushBullet(); flushOrdered(); flushQuote()
            paragraphLines.append(line)
        }

        // Fence yang belum tertutup saat streaming: tetap render
        // sebagai blok kode, supaya ``` tidak tampil mentah.
        if inCode {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushNonCode()
        return blocks
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        guard let first = line.first, first == "-" || first == "*" || first == "_" else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for character in line {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level), line.count > level else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: level)
        guard line[afterHashes] == " " else { return nil }
        let text = String(line[line.index(after: afterHashes)...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func parseBullet(_ line: String) -> String? {
        guard let first = line.first, first == "-" || first == "*" || first == "+",
              line.count > 1, line[line.index(after: line.startIndex)] == " " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func parseOrdered(_ line: String) -> (Int, String)? {
        var index = line.startIndex
        var digits = ""
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits), index < line.endIndex,
              (line[index] == "." || line[index] == ")") else { return nil }
        let afterMarker = line.index(after: index)
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        return (number, String(line[line.index(after: afterMarker)...]))
    }
}

/// View jawaban asisten: blok-blok Markdown dari `MarkdownParser`.
public struct MarkdownContentView: View {
    private let text: String
    private let isStreaming: Bool

    public init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index], appendCursor: isStreaming && index == blocks.count - 1)
            }
            // Kursor streaming tidak bisa menempel di blok kode/pemisah:
            // tampilkan sebagai baris sendiri di bawahnya.
            if isStreaming, let last = blocks.last, !isTextBlock(last) {
                Text("▍")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isTextBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading, .bullet, .ordered, .quote: return true
        case .code, .divider: return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, appendCursor: Bool) -> some View {
        switch block {
        case .paragraph(let string):
            inlineText(string, appendCursor: appendCursor)
        case .heading(let level, let string):
            inlineText(string, appendCursor: appendCursor)
                .font(level == 1 ? .title3 : level == 2 ? .headline : .subheadline)
                .bold()
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        inlineText(items[index], appendCursor: appendCursor && index == items.count - 1)
                    }
                }
            }
        case .ordered(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(start + index).")
                            .monospacedDigit()
                        inlineText(items[index], appendCursor: appendCursor && index == items.count - 1)
                    }
                }
            }
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .divider:
            Divider()
        case .quote(let string):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inlineText(string, appendCursor: appendCursor)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inlineText(_ string: String, appendCursor: Bool) -> some View {
        Text(inlineAttributed(string, appendCursor: appendCursor))
            .textSelection(.enabled)
    }

    /// Sintaks inline (tebal, miring, kode inline, coret, tautan).
    /// Kalau parsing gagal — wajar saat streaming karena penanda belum
    /// tertutup — jatuh ke teks polos. Kursor ditambahkan SEBELUM
    /// parsing supaya tidak merusak penanda di tengah teks; kalau
    /// parsing gagal, kursor tetap tampil di fallback polos.
    private func inlineAttributed(_ string: String, appendCursor: Bool) -> AttributedString {
        let source = appendCursor ? string + " ▍" : string
        return (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

/// Blok kode fenced dengan tombol Salin di header.
///
/// Menyalin ISI KODE MENTAH (tanpa fence, tanpa nama bahasa) ke
/// clipboard, supaya bisa langsung ditempel di editor.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.light()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Tersalin" : "Salin", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
