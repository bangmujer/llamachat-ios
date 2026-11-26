import ActivityKit
import Foundation

/// Atribut Live Activity untuk download model.
///
/// File ini dipakai DUA target yang berbeda modul: app utama (yang
/// meminta, memperbarui, dan mengakhiri activity dari
/// `ModelDownloadManager`) dan widget extension (yang menggambar
/// Dynamic Island + Lock Screen). Karena itu:
/// - hanya bergantung pada ActivityKit/Foundation (aman untuk
///   extension yang API-only),
/// - semua properti + init dideklarasikan `public` (init memberwise
///   bawaan Swift itu internal dan tidak terlihat antar modul).
public struct DownloadActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {
        public var fileName: String
        public var receivedBytes: Int64
        public var totalBytes: Int64
        public var progress: Double
        public var stateText: String
        public var speedBytesPerSec: Double

        public init(
            fileName: String,
            receivedBytes: Int64,
            totalBytes: Int64,
            progress: Double,
            stateText: String,
            speedBytesPerSec: Double
        ) {
            self.fileName = fileName
            self.receivedBytes = receivedBytes
            self.totalBytes = totalBytes
            self.progress = progress
            self.stateText = stateText
            self.speedBytesPerSec = speedBytesPerSec
        }

        public var percentText: String {
            "\(Int((progress * 100).rounded()))%"
        }

        public var detailText: String {
            var parts: [String] = [stateText]
            let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
            if totalBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                parts.append("\(received) / \(total)")
            } else {
                parts.append(received)
            }
            if speedBytesPerSec > 0 {
                let speed = ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file)
                parts.append("\(speed)/dtk")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// ID download yang ditampilkan. Dipakai app utama untuk
    /// mengenali activity yang masih hidup dari peluncuran
    /// sebelumnya (adopsi, bukan duplikat).
    public var downloadID: UUID

    public init(downloadID: UUID) {
        self.downloadID = downloadID
    }
}
