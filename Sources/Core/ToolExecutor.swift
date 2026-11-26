import Contacts
import EventKit
import Foundation
import UIKit

/// Pelaksana tool agent.
///
/// Setiap method mengembalikan STRING hasil untuk diberikan kembali ke
/// model sebagai konteks generation kedua. String hasil selalu
/// berbahasa Indonesia, pendek, dan dibatasi 2000 karakter supaya
/// tidak menghabiskan konteks. Kegagalan (izin ditolak, argumen tidak
/// valid, penyimpanan gagal) juga dikembalikan sebagai string, BUKAN
/// dilempar — model harus bisa menjelaskan kegagalan itu ke pengguna.
///
/// Semua berjalan di MainActor: EventKit dan `UIApplication.open`
/// memang harus dari main thread, dan ViewModel yang memanggil juga
/// MainActor.
@MainActor
public final class ToolExecutor {
    private let eventStore = EKEventStore()
    private let contactStore = CNContactStore()

    public init() {}

    public func execute(_ request: ToolCallRequest) async -> String {
        switch request.tool {
        case .currentTime:
            return currentTime()
        case .deviceInfo:
            return deviceInfo()
        case .calendarEvents:
            return await calendarEvents(daysAhead: request.int("daysAhead") ?? 7)
        case .createCalendarEvent:
            return await createCalendarEvent(request)
        case .createReminder:
            return await createReminder(request)
        case .searchContacts:
            return await searchContacts(query: request.string("query") ?? "")
        case .runShortcut:
            return runShortcut(name: request.string("name") ?? "")
        case .webSearch:
            return await webSearch(query: request.string("query") ?? "", count: request.int("count") ?? 5)
        case .webFetch:
            return await webFetch(urlString: request.string("url") ?? "")
        }
    }

    // MARK: - Tanpa izin

    private func currentTime() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        formatter.timeZone = .current
        return "Waktu saat ini: \(formatter.string(from: Date())) (zona waktu \(TimeZone.current.identifier))."
    }

    private func deviceInfo() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let batteryPercent = device.batteryLevel >= 0
            ? "\(Int(device.batteryLevel * 100))%"
            : "tidak diketahui"
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "mengisi daya"
        case .full: batteryState = "penuh"
        case .unplugged: batteryState = "tidak mengisi daya"
        case .unknown: batteryState = "tidak diketahui"
        @unknown default: batteryState = "tidak diketahui"
        }
        var freeSpace = "tidak diketahui"
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attributes[.systemFreeSize] as? Int64 {
            freeSpace = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        }
        return """
        Perangkat: \(device.model) (\(device.name)), \(device.systemName) \(device.systemVersion). \
        Baterai: \(batteryPercent) (\(batteryState)). Ruang kosong: \(freeSpace). \
        Zona waktu: \(TimeZone.current.identifier). Bahasa: \(Locale.current.identifier).
        """
    }

    // MARK: - Kalender & pengingat (EventKit)

    private func calendarEvents(daysAhead: Int) async -> String {
        let days = min(max(daysAhead, 1), 30)
        guard await requestCalendarAccess() else {
            return "Izin Kalender belum diberikan. Minta pengguna mengaktifkannya di Pengaturan iPhone > Privasi & Keamanan > Kalender > LlamaChat, lalu coba lagi."
        }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
            return "Gagal menghitung rentang tanggal."
        }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
        guard !events.isEmpty else {
            return "Tidak ada acara kalender dalam \(days) hari ke depan."
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let lines = events.map { event in
            let when = formatter.string(from: event.startDate)
            let calendar = event.calendar?.title ?? "Kalender"
            return "- \(when): \(event.title ?? "(tanpa judul)") (\(calendar))"
        }
        return truncate("Acara kalender \(days) hari ke depan:\n" + lines.joined(separator: "\n"))
    }

    private func createCalendarEvent(_ request: ToolCallRequest) async -> String {
        guard let title = request.string("title"), !title.isEmpty else {
            return "Gagal: argumen 'title' wajib diisi."
        }
        guard let startText = request.string("start"),
              let start = parseDate(startText) else {
            return "Gagal: argumen 'start' harus tanggal-jam yang valid (mis. 2026-11-27T09:00:00)."
        }
        guard await requestCalendarAccess() else {
            return "Izin Kalender belum diberikan. Minta pengguna mengaktifkannya di Pengaturan iPhone > Privasi & Keamanan > Kalender > LlamaChat, lalu coba lagi."
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval((request.int("durationMinutes") ?? 60) * 60))
        event.notes = request.string("notes")
        event.calendar = eventStore.defaultCalendarForNewEvents
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "id_ID")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Acara '\(title)' berhasil dibuat pada \(formatter.string(from: start)) di kalender \(event.calendar?.title ?? "kalender")."
        } catch {
            return "Gagal menyimpan acara kalender: \(error.localizedDescription)"
        }
    }

    private func createReminder(_ request: ToolCallRequest) async -> String {
        guard let title = request.string("title"), !title.isEmpty else {
            return "Gagal: argumen 'title' wajib diisi."
        }
        guard await requestRemindersAccess() else {
            return "Izin Pengingat belum diberikan. Minta pengguna mengaktifkannya di Pengaturan iPhone > Privasi & Keamanan > Pengingat > LlamaChat, lalu coba lagi."
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueText = request.string("due"), let due = parseDate(dueText) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        }
        do {
            try eventStore.save(reminder, commit: true)
            return "Pengingat '\(title)' berhasil dibuat."
        } catch {
            return "Gagal menyimpan pengingat: \(error.localizedDescription)"
        }
    }

    private func requestCalendarAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess: return true
        case .notDetermined: return (try? await eventStore.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    private func requestRemindersAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess: return true
        case .notDetermined: return (try? await eventStore.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }

    // MARK: - Kontak

    private func searchContacts(query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Gagal: argumen 'query' (nama yang dicari) wajib diisi."
        }
        guard await requestContactsAccess() else {
            return "Izin Kontak belum diberikan. Minta pengguna mengaktifkannya di Pengaturan iPhone > Privasi & Keamanan > Kontak > LlamaChat, lalu coba lagi."
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(matchingName: trimmed)
        var lines: [String] = []
        do {
            try contactStore.enumerateContacts(with: request) { contact, _ in
                guard lines.count < 10 else { return }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "(tanpa nama)"
                var details: [String] = []
                if let phone = contact.phoneNumbers.first {
                    details.append(phone.value.stringValue)
                }
                if let email = contact.emailAddresses.first {
                    details.append(email.value as String)
                }
                lines.append(details.isEmpty ? "- \(name)" : "- \(name): \(details.joined(separator: ", "))")
            }
        } catch {
            return "Gagal mencari kontak: \(error.localizedDescription)"
        }
        guard !lines.isEmpty else {
            return "Tidak ada kontak yang cocok dengan '\(trimmed)'."
        }
        return truncate("Kontak yang cocok dengan '\(trimmed)':\n" + lines.joined(separator: "\n"))
    }

    private func requestContactsAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                contactStore.requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        default: return false
        }
    }

    // MARK: - Shortcut

    private func runShortcut(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Gagal: argumen 'name' (nama Shortcut) wajib diisi."
        }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
        guard let url = components.url else {
            return "Gagal: nama Shortcut tidak bisa dibuat menjadi URL."
        }
        UIApplication.shared.open(url)
        return "Shortcut '\(trimmed)' dibuka di aplikasi Shortcuts. Hasil akhirnya tidak bisa dibaca kembali oleh LlamaChat — Shortcut berjalan di luar app."
    }

    // MARK: - Internet (webSearch / webFetch)

    /// Hasil pencarian web: satu baris per hasil, dengan URL sumber.
    ///
    /// Tanpa API key: sumber utama adalah halaman hasil DuckDuckGo
    /// (HTML, di-parse polanya), dengan fallback ke OpenSearch
    /// Wikipedia (id lalu en). Keduanya bisa berubah/diblokir sewaktu-
    /// waktu oleh penyedia — kalau begitu, kembalikan pesan gagal yang
    /// jujur, bukan hasil karangan. Query pengguna dikirim apa adanya
    /// ke mesin pencari; tool ini nonaktif secara default dan hanya
    /// jalan kalau pengguna mengaktifkannya di Settings.
    private struct WebResult {
        let title: String
        let snippet: String
        let url: String
    }

    private func webSearch(query: String, count: Int) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Gagal: argumen 'query' (kata kunci pencarian) wajib diisi."
        }
        let limit = min(max(count, 1), 8)
        if WebSearchSettings.isGoogleConfigured,
           let results = await googleSearch(query: trimmed, limit: limit), !results.isEmpty {
            return truncate(formatWebResults(results, query: trimmed))
        }
        if let results = await duckDuckGoSearch(query: trimmed, limit: limit), !results.isEmpty {
            return truncate(formatWebResults(results, query: trimmed))
        }
        if let results = await wikipediaSearch(query: trimmed, limit: limit), !results.isEmpty {
            return truncate(formatWebResults(results, query: trimmed))
        }
        return "Pencarian internet tidak menemukan hasil untuk '\(trimmed)', atau mesin pencari sedang tidak bisa dijangkau. Coba kata kunci lain."
    }

    private func formatWebResults(_ results: [WebResult], query: String) -> String {
        let lines = results.enumerated().map { index, result in
            let snippet = result.snippet.isEmpty ? "(tanpa cuplikan)" : result.snippet
            return "\(index + 1). \(result.title)\n   \(snippet)\n   Sumber: \(result.url)"
        }
        return "Hasil pencarian untuk '\(query)':\n" + lines.joined(separator: "\n")
    }

    /// Pencarian Google via Programmable Search (Custom Search JSON API).
    ///
    /// Hanya dipakai kalau pengguna mengisi API key + Search Engine ID
    /// di Settings (disimpan di Keychain). Gagal apa pun — kunci belum
    /// diisi, kuota habis, error API — mengembalikan nil supaya
    /// `webSearch` jatuh ke DuckDuckGo/Wikipedia, bukan mengarang
    /// hasil. Kunci tidak pernah ditulis ke log.
    private func googleSearch(query: String, limit: Int) async -> [WebResult]? {
        let apiKey = WebSearchSettings.apiKey
        let engineID = WebSearchSettings.engineID
        guard !apiKey.isEmpty, !engineID.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.googleapis.com/customsearch/v1")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: engineID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: String(limit)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return nil }
            let results = items.compactMap { item -> WebResult? in
                guard let title = item["title"] as? String, !title.isEmpty,
                      let link = item["link"] as? String, !link.isEmpty else { return nil }
                return WebResult(title: title, snippet: item["snippet"] as? String ?? "", url: link)
            }
            return results.isEmpty ? nil : results
        } catch {
            return nil
        }
    }

    private func duckDuckGoSearch(query: String, limit: Int) async -> [WebResult]? {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }
            return parseDuckDuckGo(html: html, limit: limit)
        } catch {
            return nil
        }
    }

    private func parseDuckDuckGo(html: String, limit: Int) -> [WebResult] {
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let linkMatches = linkRegex.matches(in: html, range: range)
        let snippetMatches = snippetRegex.matches(in: html, range: range)
        var results: [WebResult] = []
        for (index, match) in linkMatches.enumerated() {
            guard results.count < limit,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else { continue }
            guard let url = cleanDuckDuckGoURL(String(html[hrefRange])) else { continue }
            let title = Self.stripTagsAndEntities(String(html[titleRange]))
            var snippet = ""
            if index < snippetMatches.count,
               let snippetRange = Range(snippetMatches[index].range(at: 1), in: html) {
                snippet = Self.stripTagsAndEntities(String(html[snippetRange]))
            }
            guard !title.isEmpty else { continue }
            results.append(WebResult(title: title, snippet: snippet, url: url))
        }
        return results
    }

    private func cleanDuckDuckGoURL(_ href: String) -> String? {
        var cleaned = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uddgRange = cleaned.range(of: "uddg=") {
            let after = cleaned[uddgRange.upperBound...]
            let encoded = after.split(separator: "&").first.map(String.init) ?? String(after)
            cleaned = encoded.removingPercentEncoding ?? encoded
        }
        if cleaned.hasPrefix("//") {
            cleaned = "https:" + cleaned
        }
        guard let url = URL(string: cleaned), url.scheme == "http" || url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }

    private func wikipediaSearch(query: String, limit: Int) async -> [WebResult]? {
        for language in ["id", "en"] {
            var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")
            components?.queryItems = [
                URLQueryItem(name: "action", value: "opensearch"),
                URLQueryItem(name: "search", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "namespace", value: "0"),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      json.count == 4,
                      let titles = json[1] as? [String],
                      let descriptions = json[2] as? [String],
                      let urls = json[3] as? [String]
                else { continue }
                var results: [WebResult] = []
                for index in titles.indices where index < urls.count {
                    let snippet = index < descriptions.count ? descriptions[index] : ""
                    results.append(WebResult(title: titles[index], snippet: snippet, url: urls[index]))
                }
                if !results.isEmpty { return results }
            } catch {
                continue
            }
        }
        return nil
    }

    private func webFetch(urlString: String) async -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return "Gagal: argumen 'url' harus URL https yang valid."
        }
        if Self.isPrivateHost(host) {
            return "Ditolak: LlamaChat hanya boleh membuka halaman web publik, bukan alamat lokal atau jaringan dalam."
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Gagal membuka halaman: server tidak merespons dengan benar."
            }
            guard (200..<300).contains(http.statusCode) else {
                return "Gagal membuka halaman: server menjawab HTTP \(http.statusCode)."
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard contentType.isEmpty || contentType.contains("text/html") || contentType.contains("text/plain") else {
                return "Halaman ini bukan teks (tipe: \(contentType)). LlamaChat hanya bisa membaca halaman teks/HTML."
            }
            let capped = Data(data.prefix(200_000))
            guard let html = String(data: capped, encoding: .utf8)
                    ?? String(data: capped, encoding: .isoLatin1) else {
                return "Isi halaman tidak bisa dibaca sebagai teks."
            }
            let title = Self.extractTitle(from: html)
            let text = Self.htmlToText(html)
            guard !text.isEmpty else {
                return "Halaman '\(trimmed)' tidak punya teks yang bisa dibaca (mungkin butuh JavaScript)."
            }
            let header = title.map { "Judul: \($0)\nSumber: \(trimmed)\n\n" } ?? "Sumber: \(trimmed)\n\n"
            return truncate(header + text, limit: 3000)
        } catch {
            return "Gagal membuka halaman: \(error.localizedDescription)"
        }
    }

    private static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func isPrivateHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") { return true }
        if lower.hasPrefix("127.") || lower.hasPrefix("10.") || lower.hasPrefix("192.168.") { return true }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    private static func extractTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<title[^>]*>(.*?)</title>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let titleRange = Range(match.range(at: 1), in: html) else { return nil }
        let title = stripTagsAndEntities(String(html[titleRange]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func htmlToText(_ html: String) -> String {
        var text = replaceMatches(pattern: #"<(script|style)[^>]*>.*?</\1>"#, in: html)
        text = replaceMatches(pattern: #"<[^>]+>"#, in: text)
        text = stripTagsAndEntities(text)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static func replaceMatches(pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    private static func stripTagsAndEntities(_ text: String) -> String {
        var result = replaceMatches(pattern: #"<[^>]+>"#, in: text)
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        result = decodeNumericEntities(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#) else {
            return text
        }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let codeRange = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let code = String(text[codeRange])
            let value: UInt32?
            if code.hasPrefix("x") {
                value = UInt32(code.dropFirst(), radix: 16)
            } else {
                value = UInt32(code)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    // MARK: - Bantuan

    private func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            fallback.dateFormat = format
            if let date = fallback.date(from: text) { return date }
        }
        return nil
    }

    private func truncate(_ text: String, limit: Int = 2000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… (dipotong)"
    }
}
