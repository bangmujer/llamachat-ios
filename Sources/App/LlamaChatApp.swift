import SwiftUI
import UIKit

/// Entry point Fase C.
///
/// - UI utama adalah `ChatView` (satu percakapan di memori).
/// - SwiftData BELUM dipakai; container SwiftData datang di Fase D
///   bersama persistensi percakapan.
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

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(engine: engine)
            }
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
