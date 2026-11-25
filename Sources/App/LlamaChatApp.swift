import SwiftUI
import SwiftData
import UIKit

/// Entry point Fase D.
///
/// - UI utama adalah `ChatView` (satu percakapan di memori).
/// - Persistensi SwiftData AKTIF mulai Fase D: `ModelContainer` dibuat
///   di sini dan diteruskan ke `ChatView` lewat environment (untuk
///   `@Query` di daftar percakapan) dan lewat `mainContext` (untuk
///   `ChatViewModel`). Kalau pembuatan container penyimpanan gagal
///   (mis. database korup), dipakai container in-memory supaya app
///   tetap jalan tanpa riwayat tersimpan — kegagalan itu tidak boleh
///   membuat app tidak bisa dibuka sama sekali.
/// - Satu-satunya network call adalah download model lewat background
///   URLSession di `ModelDownloadManager`, yang hanya jalan dari
///   Model Manager atas inisiatif pengguna. `AppDelegate` di bawah
///   meneruskan completion handler background session sistem ke
///   manager itu.
@main
struct LlamaChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Actor disimpan sebagai properti `let` di App. Semua method-nya
    // dipanggil dengan `await` dari Task UI, sehingga C API berjalan di
    // executor actor (background), bukan di main thread.
    private let engine = LlamaEngine()

    private let container: ModelContainer = {
        let schema = Schema([Conversation.self, StoredMessage.self])
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            // Fallback in-memory: app tetap bisa dipakai, riwayat tidak
            // tersimpan antar sesi. Kegagalan kedua di sini praktis
            // tidak mungkin (tidak ada file yang dibuka); kalau terjadi,
            // crash dengan pesan yang jelas lebih baik daripada diam-diam
            // kehilangan data.
            return try! ModelContainer( // swiftlint:disable:this force_try
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(engine: engine, modelContext: container.mainContext)
            }
            .modelContainer(container)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                Task {
                    await engine.handleMemoryWarning()
                }
            }
        }
    }
}

/// Satu-satunya tugas AppDelegate: meneruskan completion handler
/// background URLSession dari sistem ke `ModelDownloadManager`, supaya
/// iOS tahu kapan event background download selesai diproses.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ModelDownloadManager.shared.setBackgroundCompletionHandler(completionHandler, for: identifier)
    }
}
