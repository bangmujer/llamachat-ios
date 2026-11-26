import Foundation

/// Daftar tool agent (Fase 2 + Agent).
///
/// BATAS IBOX: tool di sini HANYA yang bisa dilakukan app iOS biasa
/// dari dalam sandbox + izin pengguna. App TIDAK BISA membaca isi
/// aplikasi lain (WhatsApp, SMS, Mail, dst.) dan TIDAK BISA mengubah
/// pengaturan sistem secara langsung — tidak ada tool untuk itu, dan
/// tidak boleh ada yang berpura-pura bisa. Jembatan ke kemampuan
/// sistem adalah `runShortcut`: Shortcut buatan pengguna sendiri yang
/// dijalankan lewat URL `shortcuts://`.
///
/// Aturan keamanan yang ditegakkan di `ChatViewModel`, bukan di prompt:
/// - Tool tulis / eksternal (`requiresConfirmation == true`) TIDAK
///   PERNAH jalan tanpa ketukan konfirmasi pengguna di dialog.
/// - Tool baca yang butuh izin sistem meminta izin iOS saat pertama
///   dipakai; kalau ditolak, executor mengembalikan pesan penolakan
///   sebagai hasil tool, bukan crash dan bukan diam-diam.
/// - Model 4B tidak selalu akurat memanggil tool. Karena itu hasil
///   tool selalu ditampilkan kembali ke model sebagai konteks, dan
///   jawaban akhir tetap berasal dari generation kedua — bukan dari
///   teks mentah tool.
public enum AgentTool: String, CaseIterable, Identifiable, Sendable {
    case currentTime
    case deviceInfo
    case calendarEvents
    case createCalendarEvent
    case createReminder
    case searchContacts
    case runShortcut
    case webSearch
    case webFetch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .currentTime: return "Waktu saat ini"
        case .deviceInfo: return "Info perangkat"
        case .calendarEvents: return "Lihat jadwal kalender"
        case .createCalendarEvent: return "Buat acara kalender"
        case .createReminder: return "Buat pengingat"
        case .searchContacts: return "Cari kontak"
        case .runShortcut: return "Jalankan Shortcut"
        case .webSearch: return "Cari di internet"
        case .webFetch: return "Buka halaman web"
        }
    }

    public var description: String {
        switch self {
        case .currentTime: return "Tanggal dan jam sekarang di perangkat."
        case .deviceInfo: return "Model perangkat, versi iOS, baterai, ruang kosong, zona waktu."
        case .calendarEvents: return "Acara kalender dalam beberapa hari ke depan. Memerlukan izin Kalender."
        case .createCalendarEvent: return "Membuat acara baru di kalender. Selalu minta konfirmasi."
        case .createReminder: return "Membuat pengingat baru. Selalu minta konfirmasi."
        case .searchContacts: return "Mencari nama di kontak. Memerlukan izin Kontak."
        case .runShortcut: return "Menjalankan Shortcut buatan pengguna lewat aplikasi Shortcuts. Selalu minta konfirmasi."
        case .webSearch: return "Mencari referensi/informasi terbaru di internet. Query dikirim ke mesin pencari."
        case .webFetch: return "Mengambil isi teks sebuah halaman web (https, publik)."
        }
    }

    /// Tool tulis/eksternal: wajib konfirmasi pengguna sebelum dieksekusi.
    public var requiresConfirmation: Bool {
        switch self {
        case .createCalendarEvent, .createReminder, .runShortcut: return true
        case .currentTime, .deviceInfo, .calendarEvents, .searchContacts, .webSearch, .webFetch: return false
        }
    }

    /// Deskripsi argumen untuk prompt tool (format JSON).
    public var argumentsDescription: String {
        switch self {
        case .currentTime, .deviceInfo:
            return "{} — tanpa argumen"
        case .calendarEvents:
            return #"{"daysAhead": angka 1-30, opsional, default 7}"#
        case .createCalendarEvent:
            return #"{"title": "teks wajib", "start": "tanggal-jam ISO8601, mis. 2026-11-27T09:00:00, wajib", "durationMinutes": angka, opsional, default 60, "notes": "teks, opsional"}"#
        case .createReminder:
            return #"{"title": "teks wajib", "due": "tanggal-jam ISO8601, opsional"}"#
        case .searchContacts:
            return #"{"query": "nama yang dicari, wajib"}"#
        case .runShortcut:
            return #"{"name": "nama Shortcut persis seperti di aplikasi Shortcuts, wajib"}"#
        case .webSearch:
            return #"{"query": "kata kunci pencarian, wajib", "count": angka 1-8, opsional, default 5}"#
        case .webFetch:
            return #"{"url": "URL https halaman yang dibuka, wajib. Pakai URL dari hasil webSearch atau dari pesan pengguna; jangan mengarang URL."}"#
        }
    }

    /// Daftar tool yang dipakai di prompt: hanya yang diaktifkan pengguna.
    public static func promptList(for tools: [AgentTool]) -> String {
        tools.map { "- \($0.rawValue): \($0.description) Argumen: \($0.argumentsDescription)" }
            .joined(separator: "\n")
    }
}

/// Instruksi tool yang disisipkan app ke system prompt HANYA saat
/// minimal satu tool aktif. Ini BUKAN system prompt pengguna — prompt
/// pengguna tetap dipakai apa adanya, instruksi ini ditambahkan
/// sesudahnya oleh ViewModel saat me-render prompt keputusan tool.
/// Model diminta menjawab HANYA dengan blok JSON kalau perlu tool;
/// kalau tidak perlu, jawab biasa tanpa JSON.
public enum ToolPrompt {
    public static func preamble(for tools: [AgentTool]) -> String {
        """
        Kamu memiliki akses ke TOOLS berikut. Pakai tool HANYA kalau jawaban membutuhkan informasi/aksi dari perangkat; kalau tidak, jawab biasa seperti biasa.

        \(AgentTool.promptList(for: tools))

        ATURAN:
        - Kalau perlu tool, balas HANYA dengan satu blok kode berikut, tanpa teks lain:
        ```json
        {"tool": "nama_tool", "arguments": {...}}
        ```
        - Satu tool per balasan. Isi argumen dengan data dari pesan pengguna; jangan mengarang tanggal, nama, atau isi yang tidak disebutkan.
        - Kalau tidak perlu tool, JANGAN menulis JSON sama sekali — jawab langsung dengan teks biasa.
        - Jangan pernah mengklaim sudah menjalankan tool; hasil tool akan diberikan kepadamu setelah tool dijalankan.
        \(tools.contains(.webSearch) || tools.contains(.webFetch) ? "- Kalau jawaban memakai hasil webSearch/webFetch, cantumkan URL sumbernya di akhir jawaban. Jangan mengarang URL yang tidak ada di hasil tool." : "")
        """
    }
}

/// Preferensi aktif/nonaktif per tool, disimpan di UserDefaults.
///
/// Default: tool baca AKTIF, tool tulis/eksternal NONAKTIF sampai
/// pengguna mengaktifkannya sendiri di Settings. Tool yang nonaktif
/// tidak muncul di prompt dan tidak bisa dipanggil model.
public enum ToolPreferences {
    private static func key(for tool: AgentTool) -> String {
        "llamachat.tool.\(tool.rawValue)"
    }

    public static var enabledTools: [AgentTool] {
        AgentTool.allCases.filter { isEnabled($0) }
    }

    public static var anyEnabled: Bool { !enabledTools.isEmpty }

    public static func isEnabled(_ tool: AgentTool) -> Bool {
        if let saved = UserDefaults.standard.object(forKey: key(for: tool)) as? Bool {
            return saved
        }
        switch tool {
        case .currentTime, .deviceInfo, .calendarEvents, .searchContacts:
            return true
        case .createCalendarEvent, .createReminder, .runShortcut, .webSearch, .webFetch:
            return false
        }
    }

    public static func setEnabled(_ tool: AgentTool, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key(for: tool))
    }
}

/// Pilihan tampilan Fase 2: Sistem / Terang / Gelap.
public enum AppearanceChoice: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    public var displayName: String {
        switch self {
        case .system: return "Mengikuti Sistem"
        case .light: return "Terang"
        case .dark: return "Gelap"
        }
    }
}
