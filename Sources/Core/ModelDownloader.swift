import Foundation

/// Download model GGUF dengan segmen paralel ala download manager
/// (mirip MDM): satu file dipecah menjadi N segmen yang diunduh
/// bersamaan lewat HTTP Range, lalu digabung. Jumlah segmen per file
/// dibaca dari UserDefaults `llamachat.downloadConnections` (1...60,
/// default 8) saat download dimulai. Maksimal 2 file mengunduh
/// bersamaan; sisanya antre.
///
/// Satu-satunya network call di app ini, dan hanya jalan kalau pengguna
/// menekan Unduh di Model Manager / Katalog dengan URL yang mereka
/// pilih sendiri (brief: download hanya dari inisiatif eksplisit
/// pengguna).
///
/// Kenapa background session + delegate: background `URLSession` tidak
/// mendukung API async/await; progress dan penyelesaian download hanya
/// tersedia lewat delegate. Session dibuat dengan identifier stabil
/// supaya download berlanjut kalau app masuk background, dan
/// `AppDelegate` meneruskan completion handler sistem ke manager ini.
///
/// Ketahanan: setiap segmen yang selesai disimpan sebagai file part di
/// Application Support, dan progresnya dicatat di `state.json`. Jeda,
/// gagal, atau app tertutup tidak menghilangkan segmen yang sudah
/// selesai — Lanjutkan hanya mengunduh segmen yang belum lengkap.
/// Saat app diluncurkan ulang, task background yatim dibatalkan dan
/// semua download yang belum selesai dipulihkan sebagai terjeda.
///
/// Kalau server tidak mendukung Range (status 200, bukan 206), manager
/// otomatis jatuh ke satu download utuh tanpa segmen. File tujuan yang
/// sudah ada TIDAK ditimpa: pengguna harus menghapus dulu di Model
/// Manager.
public final class ModelDownloadManager: NSObject, ObservableObject {

    public static let shared = ModelDownloadManager()

    public enum ItemState: Equatable, Sendable {
        case queued
        case probing
        case downloading
        case paused
        case verifying
        case finished
        case failed
    }

    public struct DownloadItem: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let url: URL
        public let fileName: String
        public var state: ItemState
        public var progress: Double
        public var receivedBytes: Int64
        public var totalBytes: Int64
        public var speedBytesPerSec: Double
        public var segmentsDone: Int
        public var segmentCount: Int
        /// Segmen yang sedang dikerjakan task download yang masih hidup.
        public var activeSegments: Int
        /// Fraksi terisi per segmen (0...1), seurutan dengan segmen.
        /// Segmen selesai = 1, segmen yang task-nya berjalan = progres
        /// task itu, sisanya 0. Dipakai strip progres per segmen di UI.
        public var segmentFractions: [Double]
        public var errorMessage: String?
    }

    @Published public private(set) var downloads: [DownloadItem] = []

    /// Dipanggil di main thread setelah satu download selesai dan file
    /// sudah terverifikasi di Models/. Dipakai Model Manager untuk
    /// me-refresh daftar model.
    public var onFinished: (() -> Void)?

    public static let maxConcurrentDownloads = 2
    public static let maxConnections = 60
    private static let minSegmentBytes: Int64 = 1_048_576
    private static let stateFileName = "state.json"

    private struct Segment: Codable {
        var start: Int64
        var end: Int64
        var completed: Bool
    }

    private struct DownloadRecord: Codable {
        var id: UUID
        var urlString: String
        var fileName: String
        var expectedSize: Int64?
        var totalBytes: Int64
        var rangesSupported: Bool
        var segments: [Segment]
    }

    private struct Runtime {
        var state: ItemState
        var taskSegments: [Int: Int] = [:]
        var inFlightBytes: [Int: Int64] = [:]
        /// Jumlah percobaan ulang per segmen (kunci: indeks segmen).
        /// Satu segmen yang error koneksi dicoba lagi sampai batas ini
        /// sebelum seluruh download dinyatakan gagal.
        var retryCounts: [Int: Int] = [:]
        var errorMessage: String?
        var lastSampleAt: Date = Date()
        var lastSampleBytes: Int64 = 0
        var speedBytesPerSec: Double = 0
    }

    /// Satu segmen yang gagal (timeout, koneksi putus) dicoba lagi
    /// sebanyak ini sebelum download dinyatakan gagal. Segmen yang
    /// sudah selesai tidak pernah diulang.
    private static let maxSegmentRetries = 3

    private let workQueue = DispatchQueue(label: "com.bangmujer.llamachat.downloads")
    private var records: [UUID: DownloadRecord] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var order: [UUID] = []
    private var lastPublishAt = Date.distantPast
    private var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.bangmujer.llamachat.model-download"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = Self.maxConnections
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        workQueue.async { [weak self] in
            guard let self else { return }
            // Task background dari peluncuran sebelumnya tidak bisa
            // dipetakan lagi ke segmennya; batalkan, lalu pulihkan
            // semua download sebagai terjeda dari state.json.
            self.session.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }
            }
            self.restoreInterruptedDownloads()
            self.publish()
        }
    }

    // MARK: - Aksi pengguna

    public func startDownload(url: URL, fileName: String, expectedSizeBytes: Int64?) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let failMessage: String?
            if url.scheme?.lowercased() != "https" {
                failMessage = "URL harus https."
            } else if cleanName.isEmpty || !cleanName.lowercased().hasSuffix(".gguf") {
                failMessage = "Nama file harus berakhiran .gguf."
            } else if cleanName.contains("/") || cleanName.contains("..") {
                failMessage = "Nama file tidak valid."
            } else if self.records.values.contains(where: { $0.fileName.lowercased() == cleanName.lowercased() }) {
                failMessage = "File \(cleanName) sedang diunduh atau terjeda."
            } else if self.destinationExists(named: cleanName) {
                failMessage = "File \(cleanName) sudah ada. Hapus dulu di daftar model."
            } else {
                failMessage = nil
            }
            if let failMessage {
                let id = UUID()
                self.records[id] = DownloadRecord(
                    id: id, urlString: url.absoluteString, fileName: cleanName,
                    expectedSize: expectedSizeBytes, totalBytes: 0,
                    rangesSupported: false, segments: []
                )
                self.runtimes[id] = Runtime(state: .failed, errorMessage: failMessage)
                self.order.append(id)
                self.publish()
                return
            }
            let id = UUID()
            self.records[id] = DownloadRecord(
                id: id, urlString: url.absoluteString, fileName: cleanName,
                expectedSize: expectedSizeBytes, totalBytes: expectedSizeBytes ?? 0,
                rangesSupported: false, segments: []
            )
            self.runtimes[id] = Runtime(state: .probing)
            self.order.append(id)
            self.publish()
            self.probe(url: url, id: id)
        }
    }

    public func pauseDownload(id: UUID) {
        workQueue.async { [weak self] in
            guard let self, var runtime = self.runtimes[id], self.records[id] != nil else { return }
            guard runtime.state == .downloading || runtime.state == .queued || runtime.state == .probing else { return }
            self.cancelTasks(for: id, runtime: &runtime)
            runtime.state = .paused
            runtime.errorMessage = nil
            self.runtimes[id] = runtime
            self.persistRecord(id: id)
            self.publish()
            self.startNextQueued()
        }
    }

    public func resumeDownload(id: UUID) {
        workQueue.async { [weak self] in
            guard let self, var runtime = self.runtimes[id], let record = self.records[id] else { return }
            guard runtime.state == .paused || runtime.state == .failed else { return }
            runtime.errorMessage = nil
            if record.segments.isEmpty {
                runtime.state = .probing
                self.runtimes[id] = runtime
                self.publish()
                if let url = URL(string: record.urlString) {
                    self.probe(url: url, id: id)
                }
                return
            }
            runtime.state = self.activeDownloadCount() < Self.maxConcurrentDownloads ? .downloading : .queued
            self.runtimes[id] = runtime
            self.publish()
            if runtime.state == .downloading {
                self.startSegmentTasks(id: id)
            }
        }
    }

    public func cancelDownload(id: UUID) {
        workQueue.async { [weak self] in
            guard let self, var runtime = self.runtimes[id] else { return }
            self.cancelTasks(for: id, runtime: &runtime)
            if let record = self.records[id] {
                try? FileManager.default.removeItem(at: self.partsDirectory(for: record))
            }
            self.records.removeValue(forKey: id)
            self.runtimes.removeValue(forKey: id)
            self.order.removeAll { $0 == id }
            self.publish()
            self.startNextQueued()
        }
    }

    /// Dipanggil AppDelegate saat iOS membangunkan app untuk background
    /// session yang sudah selesai. Handler disimpan sampai
    /// `urlSessionDidFinishEvents` memanggilnya.
    public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        backgroundCompletionHandlers[identifier] = handler
    }

    // MARK: - Probe + segmen

    private func probe(url: URL, id: UUID) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.workQueue.async {
                guard var runtime = self.runtimes[id], let record = self.records[id] else { return }
                guard runtime.state == .probing else { return }
                if let error {
                    runtime.state = .failed
                    runtime.errorMessage = "Gagal memeriksa file: \(error.localizedDescription)"
                    self.runtimes[id] = runtime
                    self.publish()
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    runtime.state = .failed
                    runtime.errorMessage = "Server tidak merespons dengan benar."
                    self.runtimes[id] = runtime
                    self.publish()
                    return
                }
                var updated = record
                if http.statusCode == 206, let total = Self.totalBytes(from: http) {
                    updated.rangesSupported = true
                    updated.totalBytes = total
                    updated.segments = Self.makeSegments(totalBytes: total, count: self.connectionCount())
                } else if http.statusCode == 200 {
                    updated.rangesSupported = false
                    let length = http.expectedContentLength
                    if length > 0 {
                        updated.totalBytes = length
                    }
                    updated.segments = [Segment(start: 0, end: -1, completed: false)]
                } else {
                    runtime.state = .failed
                    runtime.errorMessage = "Server menolak download (HTTP \(http.statusCode))."
                    self.runtimes[id] = runtime
                    self.publish()
                    return
                }
                self.records[id] = updated
                self.persistRecord(id: id)
                runtime.state = self.activeDownloadCount() < Self.maxConcurrentDownloads ? .downloading : .queued
                self.runtimes[id] = runtime
                self.publish()
                if runtime.state == .downloading {
                    self.startSegmentTasks(id: id)
                }
            }
        }
        task.resume()
    }

    private static func totalBytes(from response: HTTPURLResponse) -> Int64? {
        for (key, value) in response.allHeaderFields {
            guard let keyString = key as? String, keyString.lowercased() == "content-range",
                  let rangeString = value as? String
            else { continue }
            let parts = rangeString.split(separator: "/")
            guard parts.count == 2, let total = Int64(parts[1]) else { return nil }
            return total > 0 ? total : nil
        }
        return nil
    }

    private static func makeSegments(totalBytes: Int64, count requested: Int) -> [Segment] {
        let bySize = max(1, Int(totalBytes / minSegmentBytes))
        let count = max(1, min(requested, bySize))
        guard count > 1 else {
            return [Segment(start: 0, end: totalBytes - 1, completed: false)]
        }
        let base = totalBytes / Int64(count)
        var segments: [Segment] = []
        for index in 0..<count {
            let start = Int64(index) * base
            let end = index == count - 1 ? totalBytes - 1 : start + base - 1
            segments.append(Segment(start: start, end: end, completed: false))
        }
        return segments
    }

    private func connectionCount() -> Int {
        let saved = UserDefaults.standard.integer(forKey: "llamachat.downloadConnections")
        let value = saved == 0 ? 8 : saved
        return min(Self.maxConnections, max(1, value))
    }

    /// Buat task download untuk satu segmen (Range kalau server
    /// mendukungnya, utuh kalau tidak). Task belum di-resume; pemanggil
    /// mendaftarkannya di `runtime.taskSegments` lalu me-resume.
    private func makeSegmentTask(id: UUID, index: Int) -> URLSessionDownloadTask? {
        guard let record = records[id], let url = URL(string: record.urlString),
              record.segments.indices.contains(index)
        else { return nil }
        let segment = record.segments[index]
        let request: URLRequest
        if record.rangesSupported {
            var ranged = URLRequest(url: url)
            ranged.cachePolicy = .reloadIgnoringLocalCacheData
            ranged.setValue("bytes=\(segment.start)-\(segment.end)", forHTTPHeaderField: "Range")
            request = ranged
        } else {
            request = URLRequest(url: url)
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(id.uuidString)|\(index)"
        return task
    }

    private func startSegmentTasks(id: UUID) {
        guard var runtime = runtimes[id], let record = records[id] else { return }
        runtime.state = .downloading
        runtime.retryCounts.removeAll()
        for (index, segment) in record.segments.enumerated() where !segment.completed {
            guard let task = makeSegmentTask(id: id, index: index) else { continue }
            runtime.taskSegments[task.taskIdentifier] = index
            task.resume()
        }
        runtimes[id] = runtime
    }

    private func startNextQueued() {
        guard activeDownloadCount() < Self.maxConcurrentDownloads else { return }
        guard let id = order.first(where: { runtimes[$0]?.state == .queued }),
              var runtime = runtimes[id], records[id] != nil else { return }
        runtime.state = .downloading
        runtimes[id] = runtime
        publish()
        startSegmentTasks(id: id)
    }

    private func activeDownloadCount() -> Int {
        runtimes.values.filter { $0.state == .downloading || $0.state == .probing || $0.state == .verifying }.count
    }

    private func cancelTasks(for id: UUID, runtime: inout Runtime) {
        let taskIDs = Set(runtime.taskSegments.keys)
        session.getAllTasks { tasks in
            for task in tasks where taskIDs.contains(task.taskIdentifier) {
                task.cancel()
            }
        }
        runtime.taskSegments.removeAll()
        runtime.inFlightBytes.removeAll()
    }

    // MARK: - File part + state

    private func partsRootDirectory() -> URL {
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("DownloadParts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("DownloadParts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DownloadParts", isDirectory: true)
    }

    private func partsDirectory(for record: DownloadRecord) -> URL {
        partsRootDirectory().appendingPathComponent(record.fileName, isDirectory: true)
    }

    private func partURL(for record: DownloadRecord, index: Int) -> URL {
        partsDirectory(for: record).appendingPathComponent("part-\(index).bin")
    }

    private func persistRecord(id: UUID) {
        guard let record = records[id], !record.segments.isEmpty else { return }
        do {
            let dir = partsDirectory(for: record)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: dir.appendingPathComponent(Self.stateFileName), options: .atomic)
        } catch {
            // Kegagalan mencatat state tidak membatalkan download; segmen
            // yang selesai tetap ada sebagai file part.
        }
    }

    private func restoreInterruptedDownloads() {
        let parent = partsRootDirectory()
        guard let subdirs = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
              )
        else { return }
        for dir in subdirs {
            let stateURL = dir.appendingPathComponent(Self.stateFileName)
            guard let data = try? Data(contentsOf: stateURL),
                  let record = try? JSONDecoder().decode(DownloadRecord.self, from: data),
                  !record.segments.isEmpty
            else { continue }
            records[record.id] = record
            runtimes[record.id] = Runtime(state: .paused)
            order.append(record.id)
        }
    }

    private func destinationExists(named fileName: String) -> Bool {
        guard let dir = try? ModelLoader.modelsDirectory() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path)
    }

    // MARK: - Penyelesaian

    private func finishSegmentDownload(task: URLSessionDownloadTask, location: URL) {
        guard let description = task.taskDescription,
              let separator = description.firstIndex(of: "|"),
              let id = UUID(uuidString: String(description[..<separator])),
              let index = Int(description[description.index(after: separator)...]),
              var record = records[id], var runtime = runtimes[id]
        else { return }
        runtime.taskSegments.removeValue(forKey: task.taskIdentifier)
        runtime.inFlightBytes.removeValue(forKey: task.taskIdentifier)
        runtime.retryCounts.removeValue(forKey: index)

        if let http = task.response as? HTTPURLResponse, http.statusCode == 200, record.rangesSupported {
            // Server mengabaikan Range dan mengirim file utuh: pakai
            // file ini sebagai hasil akhir, batalkan segmen lain.
            cancelTasks(for: id, runtime: &runtime)
            runtimes[id] = runtime
            finishWithWholeFile(at: location, id: id)
            return
        }

        do {
            let dir = partsDirectory(for: record)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let part = partURL(for: record, index: index)
            if FileManager.default.fileExists(atPath: part.path) {
                try FileManager.default.removeItem(at: part)
            }
            try FileManager.default.moveItem(at: location, to: part)
            record.segments[index].completed = true
            records[id] = record
            persistRecord(id: id)
        } catch {
            runtime.state = .failed
            runtime.errorMessage = "Gagal menyimpan segmen: \(error.localizedDescription)"
            cancelTasks(for: id, runtime: &runtime)
            runtimes[id] = runtime
            publish()
            startNextQueued()
            return
        }

        if record.segments.allSatisfy({ $0.completed }) {
            runtime.state = .verifying
            runtimes[id] = runtime
            publish()
            mergeParts(id: id)
        } else {
            runtimes[id] = runtime
            publish()
        }
    }

    private func mergeParts(id: UUID) {
        guard let record = records[id], var runtime = runtimes[id] else { return }
        do {
            let dir = try ModelLoader.modelsDirectory()
            let destination = dir.appendingPathComponent(record.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? writer.close() }
            for index in record.segments.indices {
                let reader = try FileHandle(forReadingFrom: partURL(for: record, index: index))
                defer { try? reader.close() }
                while true {
                    let chunk = try reader.read(upToCount: 1 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    try writer.write(contentsOf: chunk)
                }
            }
            try ModelLoader.validateGGUFMagic(at: destination)
            let actualSize = try ModelLoader.fileSizeBytes(at: destination)
            let expected = record.expectedSize ?? (record.totalBytes > 0 ? record.totalBytes : nil)
            if let expected, expected > 0, actualSize != expected {
                try? FileManager.default.removeItem(at: destination)
                runtime.state = .failed
                runtime.errorMessage = "Ukuran file tidak cocok: diunduh \(actualSize) byte, diharapkan \(expected) byte. File dihapus."
                runtimes[id] = runtime
                publish()
                return
            }
            try ModelLoader.excludeFromBackup(destination)
            try? FileManager.default.removeItem(at: partsDirectory(for: record))
            runtime.state = .finished
            runtimes[id] = runtime
            publish()
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            startNextQueued()
        } catch {
            runtime.state = .failed
            runtime.errorMessage = "Gagal menggabungkan file: \(error.localizedDescription)"
            runtimes[id] = runtime
            publish()
            startNextQueued()
        }
    }

    private func finishWithWholeFile(at location: URL, id: UUID) {
        guard let record = records[id], var runtime = runtimes[id] else { return }
        runtime.state = .verifying
        runtimes[id] = runtime
        publish()
        do {
            let dir = try ModelLoader.modelsDirectory()
            let destination = dir.appendingPathComponent(record.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try ModelLoader.validateGGUFMagic(at: destination)
            let actualSize = try ModelLoader.fileSizeBytes(at: destination)
            if let expected = record.expectedSize, expected > 0, actualSize != expected {
                try? FileManager.default.removeItem(at: destination)
                runtime.state = .failed
                runtime.errorMessage = "Ukuran file tidak cocok: diunduh \(actualSize) byte, diharapkan \(expected) byte. File dihapus."
                runtimes[id] = runtime
                publish()
                return
            }
            try ModelLoader.excludeFromBackup(destination)
            try? FileManager.default.removeItem(at: partsDirectory(for: record))
            runtime.state = .finished
            runtimes[id] = runtime
            publish()
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            startNextQueued()
        } catch {
            runtime.state = .failed
            runtime.errorMessage = "Gagal menyimpan model: \(error.localizedDescription)"
            runtimes[id] = runtime
            publish()
            startNextQueued()
        }
    }

    // MARK: - Publikasi state ke UI

    private func publish() {
        let now = Date()
        var items: [DownloadItem] = []
        for id in order {
            guard let record = records[id], var runtime = runtimes[id],
                  let url = URL(string: record.urlString) else { continue }
            let completedBytes = record.segments
                .filter { $0.completed }
                .reduce(Int64(0)) { $0 + max(0, $1.end - $1.start + 1) }
            let received = completedBytes + runtime.inFlightBytes.values.reduce(0, +)
            let elapsed = now.timeIntervalSince(runtime.lastSampleAt)
            if elapsed >= 0.25 {
                let instant = elapsed > 0 ? Double(received - runtime.lastSampleBytes) / elapsed : 0
                runtime.speedBytesPerSec = runtime.speedBytesPerSec == 0
                    ? instant
                    : runtime.speedBytesPerSec * 0.6 + instant * 0.4
                runtime.lastSampleAt = now
                runtime.lastSampleBytes = received
                runtimes[id] = runtime
            }
            let total = record.totalBytes
            let progress: Double
            if runtime.state == .finished {
                progress = 1
            } else if total > 0 {
                progress = min(1, Double(received) / Double(total))
            } else {
                progress = 0
            }
            // Fraksi per segmen untuk strip progres: segmen selesai = 1,
            // segmen yang task-nya hidup = byte task itu / panjang segmen.
            var fractions = record.segments.map { $0.completed ? 1.0 : 0.0 }
            for (taskID, index) in runtime.taskSegments {
                guard record.segments.indices.contains(index), !record.segments[index].completed,
                      let bytes = runtime.inFlightBytes[taskID]
                else { continue }
                let segment = record.segments[index]
                let length = segment.end >= segment.start
                    ? segment.end - segment.start + 1
                    : total
                if length > 0 {
                    fractions[index] = min(1, Double(bytes) / Double(length))
                }
            }
            items.append(DownloadItem(
                id: id, url: url, fileName: record.fileName,
                state: runtime.state, progress: progress,
                receivedBytes: received, totalBytes: total,
                speedBytesPerSec: runtime.speedBytesPerSec,
                segmentsDone: record.segments.filter { $0.completed }.count,
                segmentCount: record.segments.count,
                activeSegments: runtime.taskSegments.count,
                segmentFractions: fractions,
                errorMessage: runtime.errorMessage
            ))
        }
        lastPublishAt = now
        let snapshot = items
        if Thread.isMainThread {
            downloads = snapshot
        } else {
            DispatchQueue.main.async { self.downloads = snapshot }
        }
    }

    private func publishThrottled() {
        if Date().timeIntervalSince(lastPublishAt) >= 0.25 {
            publish()
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
        workQueue.async { [weak self] in
            guard let self,
                  let description = downloadTask.taskDescription,
                  let separator = description.firstIndex(of: "|"),
                  let id = UUID(uuidString: String(description[..<separator])),
                  var runtime = self.runtimes[id]
            else { return }
            runtime.inFlightBytes[downloadTask.taskIdentifier] = totalBytesWritten
            self.runtimes[id] = runtime
            self.publishThrottled()
        }
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        workQueue.async { [weak self] in
            self?.finishSegmentDownload(task: downloadTask, location: location)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        workQueue.async { [weak self] in
            guard let self,
                  let description = task.taskDescription,
                  let separator = description.firstIndex(of: "|"),
                  let id = UUID(uuidString: String(description[..<separator])),
                  var runtime = self.runtimes[id], self.records[id] != nil
            else { return }
            guard runtime.state == .downloading else { return }
            let segmentIndex = runtime.taskSegments[task.taskIdentifier]
            runtime.taskSegments.removeValue(forKey: task.taskIdentifier)
            runtime.inFlightBytes.removeValue(forKey: task.taskIdentifier)
            // Satu segmen yang error (timeout/koneksi putus) dicoba
            // lagi sendiri sampai batas retry — segmen lain yang sedang
            // berjalan TIDAK dibatalkan, dan segmen yang sudah selesai
            // tetap tersimpan. Baru kalau retry habis, seluruh download
            // dinyatakan gagal dan pengguna bisa Lanjutkan manual.
            if let segmentIndex,
               let record = self.records[id],
               record.segments.indices.contains(segmentIndex),
               !record.segments[segmentIndex].completed {
                let attempts = runtime.retryCounts[segmentIndex, default: 0]
                if attempts < Self.maxSegmentRetries {
                    runtime.retryCounts[segmentIndex] = attempts + 1
                    self.runtimes[id] = runtime
                    if let retryTask = self.makeSegmentTask(id: id, index: segmentIndex) {
                        runtime.taskSegments[retryTask.taskIdentifier] = segmentIndex
                        self.runtimes[id] = runtime
                        retryTask.resume()
                    }
                    self.publish()
                    return
                }
            }
            runtime.state = .failed
            runtime.errorMessage = "Download gagal: \(error.localizedDescription) Segmen yang sudah selesai tersimpan — tekan Lanjutkan untuk mencoba lagi."
            self.cancelTasks(for: id, runtime: &runtime)
            self.runtimes[id] = runtime
            self.persistRecord(id: id)
            self.publish()
            self.startNextQueued()
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
