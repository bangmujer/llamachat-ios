import Foundation

/// Download model GGUF lewat background `URLSession`.
///
/// Satu-satunya network call di app ini, dan hanya jalan kalau pengguna
/// menekan Mulai Download di Model Manager dengan URL yang mereka isi
/// sendiri (brief: download hanya dari inisiatif eksplisit pengguna).
///
/// Kenapa background session + delegate, bukan `async/await`:
/// background `URLSession` tidak mendukung API async/await; progress,
/// resume, dan penyelesaian download hanya tersedia lewat delegate.
/// Session dibuat dengan identifier stabil supaya download berlanjut
/// kalau app masuk background, dan `AppDelegate` meneruskan completion
/// handler sistem ke manager ini saat semua event background selesai.
///
/// Alur: start -> downloading (progress dari `didWriteData`) ->
/// `didFinishDownloadingTo` (pindah ke Models/, validasi magic GGUF,
/// verifikasi ukuran kalau ukuran yang diharapkan diketahui, tandai
/// excludeFromBackup) -> finished. Error di tengah jalan dengan resume
/// data -> paused (bisa dilanjutkan); tanpa resume data -> failed.
/// File tujuan yang sudah ada TIDAK ditimpa: pengguna harus menghapus
/// dulu di Model Manager.
public final class ModelDownloadManager: NSObject, ObservableObject {
    public static let shared = ModelDownloadManager()

    public enum State: Equatable {
        case idle
        case downloading(progress: Double, receivedBytes: Int64, expectedBytes: Int64, fileName: String)
        case paused(progress: Double, receivedBytes: Int64, expectedBytes: Int64, fileName: String)
        case verifying(fileName: String)
        case finished(fileName: String)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    /// Dipanggil di main thread setelah satu download selesai dan file
    /// sudah terverifikasi di Models/. Dipakai Model Manager untuk
    /// me-refresh daftar model.
    public var onFinished: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.bangmujer.llamachat.model-download"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var activeTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var destinationFileName: String?
    private var expectedSizeBytes: Int64?
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private override init() {
        super.init()
    }

    // MARK: - Aksi pengguna

    public func start(url: URL, fileName: String, expectedSizeBytes: Int64?) {
        guard activeTask == nil else { return }
        guard url.scheme?.lowercased() == "https" else {
            setState(.failed("URL harus https."))
            return
        }
        let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.lowercased().hasSuffix(".gguf") else {
            setState(.failed("Nama file harus berakhiran .gguf."))
            return
        }
        do {
            let dir = try ModelLoader.modelsDirectory()
            let destination = dir.appendingPathComponent(cleanName)
            if FileManager.default.fileExists(atPath: destination.path) {
                setState(.failed("File \(cleanName) sudah ada. Hapus dulu di daftar model."))
                return
            }
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }
        destinationFileName = cleanName
        self.expectedSizeBytes = expectedSizeBytes
        resumeData = nil
        let task = session.downloadTask(with: url)
        activeTask = task
        setState(.downloading(progress: 0, receivedBytes: 0, expectedBytes: expectedSizeBytes ?? 0, fileName: cleanName))
        task.resume()
    }

    public func pause() {
        guard let task = activeTask else { return }
        let fileName = destinationFileName
        task.cancel { [weak self] data in
            guard let self else { return }
            // Completion bisa jalan di queue mana saja; semua pembacaan
            // state + penulisan resume data dilakukan di main thread.
            DispatchQueue.main.async {
                self.resumeData = data
                self.activeTask = nil
                var progress = 0.0
                var received: Int64 = 0
                var expected: Int64 = 0
                if case .downloading(let p, let r, let e, _) = self.state {
                    progress = p; received = r; expected = e
                }
                self.state = .paused(progress: progress, receivedBytes: received, expectedBytes: expected, fileName: fileName ?? "model.gguf")
            }
        }
    }

    public func resumeDownload() {
        guard activeTask == nil, let fileName = destinationFileName else { return }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
            self.resumeData = nil
        } else {
            // Tanpa resume data tidak bisa melanjutkan dari byte terakhir;
            // mulai ulang membutuhkan URL asal. Simpan URL di task
            // description tidak didukung di background session, jadi
            // kasus ini dilaporkan sebagai gagal dan pengguna memulai
            // ulang dari form download.
            setState(.failed("Tidak ada data resume. Mulai download dari awal."))
            destinationFileName = nil
            return
        }
        activeTask = task
        setState(.downloading(progress: 0, receivedBytes: 0, expectedBytes: expectedSizeBytes ?? 0, fileName: fileName))
        task.resume()
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        resumeData = nil
        destinationFileName = nil
        expectedSizeBytes = nil
        setState(.idle)
    }

    /// Dipanggil AppDelegate saat iOS membangunkan app untuk background
    /// session yang sudah selesai. Handler disimpan sampai
    /// `urlSessionDidFinishEvents` memanggilnya.
    public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletionHandlers[identifier] = handler
    }

    // MARK: - Bantuan internal

    private func setState(_ newState: State) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    private func finishDownloadedFile(at location: URL) {
        guard let fileName = destinationFileName else {
            setState(.failed("Nama file tujuan hilang saat download selesai."))
            return
        }
        setState(.verifying(fileName: fileName))
        do {
            let dir = try ModelLoader.modelsDirectory()
            let destination = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try ModelLoader.validateGGUFMagic(at: destination)
            let actualSize = try ModelLoader.fileSizeBytes(at: destination)
            if let expected = expectedSizeBytes, expected > 0, actualSize != expected {
                try? FileManager.default.removeItem(at: destination)
                setState(.failed("Ukuran file tidak cocok: diunduh \(actualSize) byte, diharapkan \(expected) byte. File dihapus."))
                return
            }
            try ModelLoader.excludeFromBackup(destination)
            activeTask = nil
            resumeData = nil
            destinationFileName = nil
            expectedSizeBytes = nil
            setState(.finished(fileName: fileName))
            onFinished?()
        } catch {
            setState(.failed("Gagal menyimpan model: \(error.localizedDescription)"))
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let fileName = destinationFileName else { return }
        let expected = expectedSizeBytes ?? totalBytesExpectedToWrite
        let progress: Double
        if expected > 0 {
            progress = Double(totalBytesWritten) / Double(expected)
        } else {
            progress = 0
        }
        setState(.downloading(
            progress: progress,
            receivedBytes: totalBytesWritten,
            expectedBytes: expected,
            fileName: fileName
        ))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        finishDownloadedFile(at: location)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        // Error -999 (cancelled) dari pause() ditangani di closure
        // cancel(byProducingResumeData:); abaikan di sini supaya state
        // paused tidak tertimpa failed.
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        activeTask = nil
        if let resume = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !resume.isEmpty {
            resumeData = resume
            let current = state
            var progress = 0.0
            var received: Int64 = 0
            var expected: Int64 = 0
            var fileName = destinationFileName ?? "model.gguf"
            if case .downloading(let p, let r, let e, let f) = current {
                progress = p; received = r; expected = e; fileName = f
            }
            setState(.paused(progress: progress, receivedBytes: received, expectedBytes: expected, fileName: fileName))
        } else {
            setState(.failed("Download gagal: \(error.localizedDescription)"))
            destinationFileName = nil
            expectedSizeBytes = nil
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        guard let identifier,
              let handler = backgroundCompletionHandlers.removeValue(forKey: identifier)
        else { return }
        DispatchQueue.main.async { handler() }
    }
}
