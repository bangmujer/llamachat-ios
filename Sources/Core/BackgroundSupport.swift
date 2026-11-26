import UIKit
import UserNotifications

/// Dukungan berjalan di latar belakang.
///
/// - Chat: satu giliran generation dibungkus `beginBackgroundTask`,
///   jadi decode tidak langsung dibekukan saat app pindah ke
///   background — iOS memberi waktu ekstra (puluhan detik, batas
///   sistem). Kalau waktu itu habis sebelum jawaban selesai, proses
///   hanya ditangguhkan dan generation dilanjutkan lagi begitu app
///   kembali ke foreground; Task-nya TIDAK dibatalkan.
/// - Download: `ModelDownloadManager` memakai background `URLSession`,
///   jadi transfer diteruskan sistem dan app dibangunkan untuk
///   menerima byte-nya; tidak perlu assertion tambahan.
/// - Notifikasi: kalau generation/download selesai selagi app di
///   background, notifikasi lokal dikirim — hanya bila pengguna
///   mengizinkan. Tanpa izin, semua tetap jalan, hanya tanpa
///   notifikasi. Tidak ada background mode di Info.plist: tidak ada
///   mode audio/voip/fetch yang dipakai.
public enum BackgroundSupport {

    /// Minta izin notifikasi sekali, dari aksi pengguna di foreground
    /// (kirim chat / mulai download). Tanpa panggilan ini, notifikasi
    /// latar belakang tidak akan pernah muncul; pemanggilan berulang
    /// tidak menampilkan dialog dua kali.
    public static func ensureNotificationAuthorization() {
        DispatchQueue.main.async {
            guard !authorizationRequested else { return }
            authorizationRequested = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Mulai assertion background. Harus dipanggil di main thread dan
    /// diakhiri `endTask` — pemanggil bertanggung jawab atas
    /// pasangannya (biasanya lewat `defer` di Task yang sama).
    /// Mengembalikan `.invalid` kalau sistem menolak (mis. sudah
    /// terlalu banyak assertion); pemanggil tetap jalan normal.
    @MainActor
    public static func beginTask(named name: String) -> UIBackgroundTaskIdentifier {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        return identifier
    }

    @MainActor
    public static func endTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// Kirim notifikasi lokal HANYA kalau app sedang di background.
    /// Di foreground tidak ada notifikasi: jawabannya sudah terlihat
    /// di layar. Harus dipanggil di main thread.
    @MainActor
    public static func notifyIfBackground(title: String, body: String) {
        guard UIApplication.shared.applicationState == .background else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static var authorizationRequested = false
}
