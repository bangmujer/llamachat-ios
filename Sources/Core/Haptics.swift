import UIKit

/// Haptik ringan Fase 2.
///
/// Satu-satunya tempat yang memanggil generator haptik, supaya tidak
/// ada `UIImpactFeedbackGenerator` tersebar di ViewModel/View. Bisa
/// dimatikan di Settings; default AKTIF. Semua pemanggilan harus dari
/// MainActor (ViewModel dan View sudah MainActor).
public enum Haptics {
    private static let enabledKey = "llamachat.hapticsEnabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    /// Ketukan ringan: pesan terkirim, tool dikonfirmasi.
    public static func light() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Selesai: generation selesai, aksi tool berhasil.
    public static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Gagal: generation error / konteks habis.
    public static func error() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
