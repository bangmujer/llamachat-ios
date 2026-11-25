import Foundation

/// Lokasi + validasi file GGUF di disk.
///
/// Fase A: HANYA locate + validate. Download (background URLSession,
/// resume, verifikasi ukuran) adalah pekerjaan Fase C dan TIDAK ada di
/// file ini. Tidak ada network call di file ini, di engine, maupun di
/// app Fase A.
public enum ModelLoader {
    /// Application Support/Models/. Dibuat kalau belum ada, dan
    /// ditandai excludeFromBackup supaya file model (gigabyte) tidak
    /// ikut backup iCloud.
    public static func modelsDirectory() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AppError.modelNotFound("Folder Application Support tidak ditemukan.")
        }
        var dir = base.appendingPathComponent("Models", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        return dir
    }

    /// Model pertama (urut nama) di Models/. Dipakai smoke test Fase A
    /// supaya tidak ada nama file yang di-hardcode di engine.
    public static func firstModel() throws -> URL {
        let dir = try modelsDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        let ggufs = urls
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = ggufs.first else {
            throw AppError.modelNotFound(
                "Tidak ada file .gguf di \(dir.path). Taruh satu file model Qwen3 di folder itu, lalu jalankan lagi."
            )
        }
        return first
    }

    public static func fileSizeBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else {
            throw AppError.modelCorrupted("File model kosong atau tidak bisa dibaca ukurannya: \(url.lastPathComponent)")
        }
        return Int64(size)
    }

    /// Validasi paling murah sebelum llama.cpp dipanggil: 4 byte pertama
    /// harus "GGUF". Ini TIDAK menggantikan validasi tensor oleh
    /// llama.cpp; file yang magic-nya benar tapi isinya rusak tetap akan
    /// ditolak saat load dan dilaporkan sebagai modelCorrupted.
    public static func validateGGUFMagic(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AppError.modelNotFound("File model tidak bisa dibuka: \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else {
            throw AppError.modelCorrupted("File model terlalu pendek untuk dibaca header GGUF-nya.")
        }
        guard head == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw AppError.modelCorrupted("File bukan GGUF (4 byte pertama bukan \"GGUF\"): \(url.lastPathComponent)")
        }
    }
}
