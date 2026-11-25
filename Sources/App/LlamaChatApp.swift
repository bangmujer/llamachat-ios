import SwiftUI
import UIKit

/// Entry point Fase A.
///
/// - Tidak ada UI chat di fase ini; `PhaseAView` adalah harness sementara
///   yang menampilkan log load + generation supaya build yang di-install
///   lewat TrollStore tetap bisa diverifikasi tanpa konsol Xcode.
/// - SwiftData BELUM dipakai di fase ini; container SwiftData datang
///   di Fase D bersama persistensi percakapan.
/// - Tidak ada network call di app ini.
@main
struct LlamaChatApp: App {
    // Actor disimpan sebagai properti `let` di App. Semua method-nya
    // dipanggil dengan `await` dari Task UI, sehingga C API berjalan di
    // executor actor (background), bukan di main thread.
    private let engine = LlamaEngine()

    var body: some Scene {
        WindowGroup {
            PhaseAView(engine: engine)
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
