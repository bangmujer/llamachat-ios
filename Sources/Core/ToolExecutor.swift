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
            return "- \(when): \(event.title) (\(calendar))"
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
