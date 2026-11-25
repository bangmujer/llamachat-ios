import SwiftUI
import UIKit

/// Entry point Fase B.
///
/// - UI utama adalah `ChatView` (satu percakapan di memori).
/// - SwiftData BELUM dipakai; container SwiftData datang di Fase D
///   bersama persistensi percakapan.
/// - Tidak ada network call di app ini (download model datang di Fase C).
@main
struct LlamaChatApp: App {
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
