import Foundation

/// Nilai argumen tool yang sudah didecode dari JSON.
///
/// Disimpan sebagai enum, bukan `[String: Any]`, supaya
/// `ToolCallRequest` tetap `Sendable` dan tidak ada force-cast di
/// ViewModel/executor. Hanya skalar yang didukung — semua tool Fase 2
/// hanya butuh string/angka/bool.
public enum ToolArgument: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

/// Satu permintaan pemanggilan tool dari model.
public struct ToolCallRequest: Equatable, Sendable {
    public let tool: AgentTool
    public let arguments: [String: ToolArgument]

    public func string(_ name: String) -> String? {
        guard case .string(let value) = arguments[name] else { return nil }
        return value
    }

    public func int(_ name: String) -> Int? {
        switch arguments[name] {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let text): return Int(text)
        case .bool, .none: return nil
        }
    }

    /// Ringkasan satu baris untuk dialog konfirmasi.
    public var summary: String {
        let args = arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return args.isEmpty ? tool.displayName : "\(tool.displayName) (\(args))"
    }
}

extension ToolArgument: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return "\(value)"
        case .double(let value): return "\(value)"
        case .bool(let value): return "\(value)"
        }
    }
}

/// Parser blok JSON tool-call dari teks hasil generation.
///
/// Model 4B tidak selalu mengeluarkan JSON yang bersih: blok bisa
/// dibungkus fence ```json, bisa didahului teks lain, dan bisa
/// tertelan blok <think> (sudah dibuang pemanggil lewat
/// `ThinkBlock.stripped` sebelum parse). Parser ini toleran terhadap
/// itu semua, TAPI ketat soal validasi: nama tool harus ada di
/// allowlist `AgentTool`, dan `arguments` harus objek. JSON yang tidak
/// valid atau tool yang tidak dikenal -> nil (diperlakukan sebagai
/// jawaban biasa, bukan error).
public enum ToolCallParser {
    public static func parse(from text: String) -> ToolCallRequest? {
        // 1. Coba blok fence ```json ... ``` dulu (format yang diminta).
        if let fenced = extractFencedJSON(from: text), let call = decode(fenced) {
            return call
        }
        // 2. Coba rentang { ... } terluar dari teks.
        if let first = text.firstIndex(of: "{"),
           let last = text.lastIndex(of: "}"), first <= last {
            let candidate = String(text[first...last])
            if let call = decode(candidate) {
                return call
            }
        }
        return nil
    }

    /// Hapus blok fence JSON tool-call dari teks, untuk tampilan.
    /// Dipakai kalau teks keputusan ternyata jawaban biasa yang
    /// mengandung blok JSON nyasar — tampilkan sisanya saja.
    public static func strippingToolBlock(from text: String) -> String {
        guard let open = text.range(of: "```json") else { return text }
        let afterOpen = open.upperBound
        guard let close = text.range(of: "```", range: afterOpen..<text.endIndex) else { return text }
        let stripped = String(text[..<open.lowerBound]) + String(text[close.upperBound...])
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractFencedJSON(from text: String) -> String? {
        guard let open = text.range(of: "```json") else { return nil }
        let afterOpen = open.upperBound
        guard let close = text.range(of: "```", range: afterOpen..<text.endIndex) else { return nil }
        return String(text[afterOpen..<close.lowerBound])
    }

    private static func decode(_ jsonText: String) -> ToolCallRequest? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let toolName = object["tool"] as? String,
              let tool = AgentTool(rawValue: toolName) else { return nil }
        var arguments: [String: ToolArgument] = [:]
        if let rawArgs = object["arguments"] as? [String: Any] {
            for (key, value) in rawArgs {
                if let argument = decodeArgument(value) {
                    arguments[key] = argument
                }
            }
        }
        return ToolCallRequest(tool: tool, arguments: arguments)
    }

    private static func decodeArgument(_ value: Any) -> ToolArgument? {
        if let string = value as? String {
            return .string(string)
        }
        if let number = value as? NSNumber {
            // NSNumber dari JSON: objCType "c" = bool (true/false).
            if String(cString: number.objCType) == "c" {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            if double == double.rounded(.towardZero), abs(double) < 9_007_199_254_740_992 {
                return .int(number.intValue)
            }
            return .double(double)
        }
        if let bool = value as? Bool {
            return .bool(bool)
        }
        return nil
    }
}
