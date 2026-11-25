import Foundation

/// Template chat.
///
/// Keputusan Fase C: template TIDAK dirender lewat
/// `llama_chat_apply_template`. Header v1.0.0 menegaskan fungsi itu
/// "does not use a jinja parser" dan hanya mendukung daftar template
/// bawaan tertentu, jadi memanggilnya dengan template Jinja mentah dari
/// metadata GGUF bukan jalur yang bisa diandalkan untuk semua model.
/// Sebagai gantinya, `.auto` mendeteksi keluarga template dari isi
/// template metadata itu sendiri (penanda khas tiap keluarga) lewat
/// `ChatTemplate.detect(from:)`, lalu render dilakukan oleh string
/// builder murni Swift di file ini. Pengguna bisa meng-override lewat
/// Settings; override disimpan per-model di `ModelSettingsStore`.
///
/// String-string di bawah adalah bentuk ChatML / Llama 3 / Gemma /
/// Mistral yang umum; engine me-log 500 karakter pertama template
/// bawaan model supaya hasil deteksi bisa dibandingkan dengan template
/// asli model di review.
public enum ChatTemplateKind: String, CaseIterable, Codable, Sendable {
    case auto
    case chatML
    case llama3
    case gemma
    case mistral
    case raw

    public var displayName: String {
        switch self {
        case .auto: return "Otomatis (dari model)"
        case .chatML: return "ChatML"
        case .llama3: return "Llama 3"
        case .gemma: return "Gemma"
        case .mistral: return "Mistral"
        case .raw: return "Raw (tanpa template)"
        }
    }
}

public enum ChatTemplate {
    /// Tebak keluarga template dari isi template metadata model.
    /// Penanda yang dicek adalah penanda khas yang hanya muncul di
    /// keluarga itu: `<|im_start|>` (ChatML), `<|start_header_id|>`
    /// (Llama 3), `<start_of_turn>` (Gemma), `[INST]` (Mistral).
    /// Template kosong / tidak dikenal -> ChatML (keluarga Qwen3).
    public static func detect(from template: String?) -> ChatTemplateKind {
        guard let template, !template.isEmpty else { return .chatML }
        if template.contains("<|im_start|>") { return .chatML }
        if template.contains("<|start_header_id|>") { return .llama3 }
        if template.contains("<start_of_turn>") { return .gemma }
        if template.contains("[INST]") { return .mistral }
        return .chatML
    }

    /// Selesaikan pilihan pengguna: `.auto` diganti hasil deteksi dari
    /// metadata model yang sedang ter-load; pilihan eksplisit dipakai
    /// apa adanya.
    public static func resolve(kind: ChatTemplateKind, metadata: String?) -> ChatTemplateKind {
        kind == .auto ? detect(from: metadata) : kind
    }

    /// Render pesan menjadi satu prompt string, tanpa memanggil C API.
    ///
    /// `systemPrompt` kosong berarti tidak ada pesan system.
    /// Pesan assistant terakhir TIDAK ditutup: prompt diakhiri dengan
    /// penanda giliran assistant, sesuai konvensi tiap template.
    public static func render(
        kind: ChatTemplateKind,
        systemPrompt: String,
        messages: [ChatMessage]
    ) -> String {
        switch kind {
        case .auto, .chatML:
            return renderChatML(systemPrompt: systemPrompt, messages: messages)
        case .llama3:
            return renderLlama3(systemPrompt: systemPrompt, messages: messages)
        case .gemma:
            return renderGemma(systemPrompt: systemPrompt, messages: messages)
        case .mistral:
            return renderMistral(systemPrompt: systemPrompt, messages: messages)
        case .raw:
            return messages.map(\.content).joined(separator: "\n")
        }
    }

    private static func renderChatML(systemPrompt: String, messages: [ChatMessage]) -> String {
        var out = ""
        if !systemPrompt.isEmpty {
            out += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        }
        for message in messages {
            switch message.role {
            case .system:
                out += "<|im_start|>system\n\(message.content)<|im_end|>\n"
            case .user:
                out += "<|im_start|>user\n\(message.content)<|im_end|>\n"
            case .assistant:
                out += "<|im_start|>assistant\n\(message.content)<|im_end|>\n"
            }
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    private static func renderLlama3(systemPrompt: String, messages: [ChatMessage]) -> String {
        var out = "<|begin_of_text|>"
        if !systemPrompt.isEmpty {
            out += "<|start_header_id|>system<|end_header_id|>\n\n\(systemPrompt)<|eot_id|>"
        }
        for message in messages {
            switch message.role {
            case .system:
                out += "<|start_header_id|>system<|end_header_id|>\n\n\(message.content)<|eot_id|>"
            case .user:
                out += "<|start_header_id|>user<|end_header_id|>\n\n\(message.content)<|eot_id|>"
            case .assistant:
                out += "<|start_header_id|>assistant<|end_header_id|>\n\n\(message.content)<|eot_id|>"
            }
        }
        out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return out
    }

    private static func renderGemma(systemPrompt: String, messages: [ChatMessage]) -> String {
        var out = ""
        if !systemPrompt.isEmpty {
            out += "<start_of_turn>user\n\(systemPrompt)\n<end_of_turn>\n"
        }
        for message in messages {
            switch message.role {
            case .system, .user:
                out += "<start_of_turn>user\n\(message.content)<end_of_turn>\n"
            case .assistant:
                out += "<start_of_turn>model\n\(message.content)<end_of_turn>\n"
            }
        }
        out += "<start_of_turn>model\n"
        return out
    }

    private static func renderMistral(systemPrompt: String, messages: [ChatMessage]) -> String {
        var out = ""
        if !systemPrompt.isEmpty {
            out += "[INST] \(systemPrompt) [/INST]"
        }
        for message in messages {
            switch message.role {
            case .system:
                out += "[INST] \(message.content) [/INST]"
            case .user:
                out += "[INST] \(message.content) [/INST]"
            case .assistant:
                out += " \(message.content)</s>"
            }
        }
        return out
    }
}
