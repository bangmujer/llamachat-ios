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
/// Desain resume per byte: segmen diunduh dengan `URLSessionDataTask`,
/// dan setiap byte yang diterima LANGSUNG ditambahkan ke file part
/// segmen itu (`Application Support/DownloadParts/<file>/part-N.bin`)
/// beserta hitungan `received` yang dicatat di `state.json`. Jeda,
/// gagal, atau app tertutup TIDAK menghilangkan byte yang sudah
/// diterima — Lanjutkan meminta `Range` dari byte terakhir yang
/// tersimpan, bukan dari awal segmen. (Desain lama memakai
/// `URLSessionDownloadTask`: byte yang belum menjadi satu segmen utuh
/// hilang saat dibatalkan, jadi Jeda di tengah segmen ~125 MB terlihat
/// seperti "file hilang, download ulang".)
///
/// Latar belakang: session ini background `URLSession` dengan
/// identifier stabil, jadi transfer diteruskan sistem selagi app di
/// background dan app dibangunkan untuk menerima byte-nya
/// (`AppDelegate` meneruskan completion handler sistem ke manager
/// ini). Callback delegate berjalan di antrean serial yang sama
/// dengan semua mutasi state (`workQueue`), jadi tidak ada balapan
/// antara byte yang masuk dan Jeda/Batal. Saat app diluncurkan ulang,
/// task yang masih hidup diadopsi kembali (bukan dibatalkan), dan
/// download yang tidak punya task hidup dipulihkan sebagai terjeda.
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
        /// Segmen selesai = 1, sisanya = byte tersimpan / panjang segmen.
        /// Dipakai strip progres per segmen di UI.
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
        /// Byte yang sudah tersimpan di file part segmen ini. Punya
        /// nilai default supaya `state.json` dari build lama (tanpa
        /// kolom ini) tetap bisa dibaca — segmennya dianggap mulai
        /// dari nol.
        var received: Int64 = 0
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
        /// Task data yang hidup, per indeks segmen.
        var tasks: [Int: URLSessionDataTask] = [:]
        /// Handle tulis file part yang terbuka, per indeks segmen.
        var handles: [Int: FileHandle] = [:]
        /// Panjang yang diharapkan per segmen dari respons server
        /// (0 = tidak diketahui; untuk segmen utuh tanpa Range).
        var expectedLengths: [Int: Int64] = [:]
        /// Jumlah percobaan ulang per segmen (kunci: indeks segmen).
        /// Satu segmen yang error koneksi dicoba lagi sampai batas ini
        /// sebelum seluruh download dinyatakan gagal. Byte yang sudah
        /// tersimpan tidak pernah diunduh ulang.
        var retryCounts: [Int: Int] = [:]
        var errorMessage: String?
        var lastSampleAt: Date = Date()
        var lastSampleBytes: Int64 = 0
        var speedBytesPerSec: Double = 0
        var lastPersistAt: Date = Date.distantPast
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

    /// Antrean delegate serial yang berjalan DI ATAS `workQueue`:
    /// callback byte yang masuk dan aksi pengguna (Jeda/Lanjutkan/
    /// Batal) tidak pernah berjalan bersamaan, jadi byte yang sudah
    /// ditambahkan ke file part tidak bisa tertinggal dari catatan.
    private let delegateQueue = OperationQueue()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.bangmujer.llamachat.model-download"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = Self.maxConnections
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = workQueue
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    private override init() {
        super.init()
        workQueue.async { [weak self] in
            guard let self else { return }
            // Pulihkan download yang belum selesai sebagai terjeda
            // dari state.json, lalu adopsi kembali task background
            // yang masih hidup (mis. app dibangunkan sistem untuk
            // menerima byte) — task yatim tanpa catatan dibatalkan.
            self.restoreInterruptedDownloads()
            self.adoptLiveTasks()
            self.publish()
        }
    }

    // MARK: - Aksi pengguna

    public func startDownload(url: URL, fileName: String, expectedSizeBytes: Int64?) {
        BackgroundSupport.ensureNotificationAuthorization()
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
            // Batalkan task yang hidup. Byte yang sudah diterima TIDAK
            // hilang: semuanya sudah ditambahkan ke file part dan
            // tercatat di state.json sebelum baris ini.
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
        BackgroundSupport.ensureNotificationAuthorization()
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
                    updated.segments = [Segment(start: 0, end: -1, completed: false, received: 0)]
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
            return [Segment(start: 0, end: totalBytes - 1, completed: false, received: 0)]
        }
        let base = totalBytes / Int64(count)
        var segments: [Segment] = []
        for index in 0..<count {
            let start = Int64(index) * base
            let end = index == count - 1 ? totalBytes - 1 : start + base - 1
            segments.append(Segment(start: start, end: end, completed: false, received: 0))
        }
        return segments
    }

    private func connectionCount() -> Int {
        let saved = UserDefaults.standard.integer(forKey: "llamachat.downloadConnections")
        let value = saved == 0 ? 8 : saved
        return min(Self.maxConnections, max(1, value))
    }

    /// Panjang segmen yang dipakai untuk progres/penyelesaian: untuk
    /// segmen utuh tanpa Range (end = -1) pakai total file bila
    /// diketahui, kalau tidak pakai byte yang sudah tersimpan.
    private static func segmentLength(_ segment: Segment, totalBytes: Int64) -> Int64 {
        if segment.end >= segment.start { return segment.end - segment.start + 1 }
        if totalBytes > 0 { return totalBytes }
        return segment.received
    }

    /// Buat task data untuk satu segmen. `Range` dimulai dari byte
    /// terakhir yang sudah tersimpan di file part — bukan dari awal
    /// segmen — supaya Jeda/Lanjutkan tidak mengunduh ulang byte
    /// yang sama.
    private func makeSegmentTask(id: UUID, index: Int) -> URLSessionDataTask? {
        guard let record = records[id], let url = URL(string: record.urlString),
              record.segments.indices.contains(index)
        else { return nil }
        let segment = record.segments[index]
        let request: URLRequest
        if record.rangesSupported {
            var ranged = URLRequest(url: url)
            ranged.cachePolicy = .reloadIgnoringLocalCacheData
            let from = segment.start + segment.received
            ranged.setValue("bytes=\(from)-\(segment.end)", forHTTPHeaderField: "Range")
            request = ranged
        } else {
            request = URLRequest(url: url)
        }
        let task = session.dataTask(with: request)
        task.taskDescription = "\(id.uuidString)|\(index)"
        return task
    }

    private func startSegmentTasks(id: UUID) {
        guard var runtime = runtimes[id], var record = records[id] else { return }
        runtime.state = .downloading
        runtime.retryCounts.removeAll()
        var changed = false
        for (index, segment) in record.segments.enumerated() where !segment.completed {
            let length = Self.segmentLength(segment, totalBytes: record.totalBytes)
            if length > 0, segment.received >= length {
                // Sudah lengkap dari upaya sebelumnya (mis. app
                // tertutup tepat setelah byte terakhir masuk).
                record.segments[index].completed = true
                changed = true
                continue
            }
            guard let task = makeSegmentTask(id: id, index: index) else { continue }
            runtime.tasks[index] = task
            task.resume()
        }
        if changed {
            records[id] = record
            persistRecord(id: id)
        }
        runtimes[id] = runtime
        if record.segments.allSatisfy({ $0.completed }) {
            runtime.state = .verifying
            runtimes[id] = runtime
            publish()
            mergeParts(id: id)
        }
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

    /// Batalkan task yang hidup dan tutup handle part. Sinkron: tidak
    /// ada lagi `getAllTasks` asinkron di jalur Jeda/Batal, jadi tidak
    /// ada task yang sempat lolos dari pembatalan.
    private func cancelTasks(for id: UUID, runtime: inout Runtime) {
        for task in runtime.tasks.values {
            task.cancel()
        }
        runtime.tasks.removeAll()
        closeHandles(runtime: &runtime)
    }

    private func closeHandles(runtime: inout Runtime) {
        for handle in runtime.handles.values {
            try? handle.close()
        }
        runtime.handles.removeAll()
    }

    private func closeHandle(index: Int, runtime: inout Runtime) {
        if let handle = runtime.handles.removeValue(forKey: index) {
            try? handle.close()
        }
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
            // Kegagalan mencatat state tidak membatalkan download; byte
            // yang sudah tersimpan tetap ada sebagai file part.
        }
    }

    private func persistThrottled(id: UUID) {
        guard var runtime = runtimes[id] else { return }
        let now = Date()
        guard now.timeIntervalSince(runtime.lastPersistAt) >= 1 else { return }
        runtime.lastPersistAt = now
        runtimes[id] = runtime
        persistRecord(id: id)
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

    /// Adopsi task background yang masih hidup (app dibangunkan sistem
    /// untuk menerima byte): task yang catatannya ada dan segmennya
    /// belum selesai didaftarkan kembali dan download-nya berjalan
    /// lagi. Task yatim — tanpa catatan, atau dari format lama
    /// (`URLSessionDownloadTask`) — dibatalkan; byte segmen yang
    /// sudah selesai tetap tersimpan dan bisa dilanjutkan manual.
    private func adoptLiveTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.workQueue.async {
                for task in tasks {
                    guard let (id, index) = Self.parseTaskDescription(task.taskDescription),
                          var runtime = self.runtimes[id],
                          let record = self.records[id],
                          record.segments.indices.contains(index),
                          !record.segments[index].completed,
                          let dataTask = task as? URLSessionDataTask
                    else {
                        task.cancel()
                        continue
                    }
                    runtime.tasks[index] = dataTask
                    if runtime.state == .paused {
                        runtime.state = .downloading
                    }
                    self.runtimes[id] = runtime
                }
                self.publish()
            }
        }
    }

    private static func parseTaskDescription(_ description: String?) -> (UUID, Int)? {
        guard let description,
              let separator = description.firstIndex(of: "|"),
              let id = UUID(uuidString: String(description[..<separator])),
              let index = Int(description[description.index(after: separator)...])
        else { return nil }
        return (id, index)
    }

    private func destinationExists(named fileName: String) -> Bool {
        guard let dir = try? ModelLoader.modelsDirectory() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path)
    }

    // MARK: - Penanganan byte masuk (delegate data task)

    /// Buka (atau pakai lagi) handle tulis file part segmen. File yang
    /// sudah ada direkonsiliasi dengan catatan: ekor byte yang tidak
    /// tercatat (mis. app tertutup di tengah penulisan) dipotong,
    /// supaya `received` dan isi file selalu cocok.
    private func openPartHandle(
        id: UUID, index: Int, record: inout DownloadRecord, runtime: inout Runtime
    ) throws -> FileHandle {
        if let handle = runtime.handles[index] { return handle }
        let dir = partsDirectory(for: record)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = partURL(for: record, index: index)
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        let attributes = try FileManager.default.attributesOfItem(atPath: part.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let kept = min(record.segments[index].received, actualSize)
        if kept != record.segments[index].received {
            record.segments[index].received = kept
        }
        if actualSize > kept {
            try handle.truncate(atOffset: UInt64(kept))
        }
        try handle.seek(toOffset: UInt64(kept))
        runtime.handles[index] = handle
        return handle
    }

    /// Respons segmen: validasi status, lalu izinkan byte mengalir.
    /// Dipanggil di `workQueue` (delegate serial di atas antrean itu).
    private func handleResponse(
        task: URLSessionDataTask, response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let (id, index) = Self.parseTaskDescription(task.taskDescription),
              var runtime = runtimes[id],
              let record = records[id],
              record.segments.indices.contains(index)
        else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            failItem(id: id, runtime: &runtime, message: "Server tidak merespons dengan benar.")
            completionHandler(.cancel)
            return
        }
        if record.rangesSupported {
            if http.statusCode == 200 {
                // Server mengabaikan Range dan mengirim file utuh:
                // jadikan satu segmen utuh dan lanjutkan dengan task
                // ini sebagai sumber file lengkap.
                convertToWholeFile(id: id, currentTask: task, totalBytes: http.expectedContentLength)
                if var converted = runtimes[id] {
                    converted.expectedLengths[0] = http.expectedContentLength > 0 ? http.expectedContentLength : 0
                    runtimes[id] = converted
                }
                completionHandler(.allow)
                return
            }
            guard http.statusCode == 206 else {
                failItem(id: id, runtime: &runtime, message: "Server menolak download (HTTP \(http.statusCode)).")
                completionHandler(.cancel)
                return
            }
            let length = Self.segmentLength(record.segments[index], totalBytes: record.totalBytes)
            runtime.expectedLengths[index] = length
            runtimes[id] = runtime
            completionHandler(.allow)
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            failItem(id: id, runtime: &runtime, message: "Server menolak download (HTTP \(http.statusCode)).")
            completionHandler(.cancel)
            return
        }
        runtime.expectedLengths[index] = http.expectedContentLength > 0 ? http.expectedContentLength : 0
        runtimes[id] = runtime
        completionHandler(.allow)
    }

    /// Byte segmen masuk: langsung ditambahkan ke file part dan
    /// dihitung. Dipanggil di `workQueue`.
    private func handleData(task: URLSessionDataTask, data: Data) {
        guard !data.isEmpty,
              let (id, index) = Self.parseTaskDescription(task.taskDescription),
              var runtime = runtimes[id],
              var record = records[id],
              record.segments.indices.contains(index),
              runtime.tasks[index]?.taskIdentifier == task.taskIdentifier,
              runtime.state == .downloading
        else { return }
        do {
            let handle = try openPartHandle(id: id, index: index, record: &record, runtime: &runtime)
            try handle.write(contentsOf: data)
            record.segments[index].received += Int64(data.count)
            records[id] = record
            runtimes[id] = runtime
            persistThrottled(id: id)
            publishThrottled()
        } catch {
            failItem(id: id, runtime: &runtime, message: "Gagal menyimpan segmen: \(error.localizedDescription)")
        }
    }

    /// Task selesai (sukses atau error). Dipanggil di `workQueue`.
    private func handleCompletion(task: URLSessionTask, error: Error?) {
        guard let (id, index) = Self.parseTaskDescription(task.taskDescription),
              var runtime = runtimes[id],
              let record = records[id],
              record.segments.indices.contains(index)
        else { return }
        // Abaikan callback dari task yang sudah diganti (retry, jeda,
        // atau konversi file utuh): hanya task terdaftar yang boleh
        // mengubah state segmen ini.
        guard runtime.tasks[index]?.taskIdentifier == task.taskIdentifier else { return }
        runtime.tasks.removeValue(forKey: index)
        closeHandle(index: index, runtime: &runtime)

        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                // Dibatalkan oleh Jeda/Batal/gagal lain: state sudah
                // diatur pemanggil pembatalan. Jangan retry.
                runtimes[id] = runtime
                return
            }
            guard runtime.state == .downloading else {
                runtimes[id] = runtime
                return
            }
            attemptRetryOrFail(
                id: id, index: index, runtime: &runtime,
                message: "Download gagal: \(error.localizedDescription)"
            )
            return
        }

        guard runtime.state == .downloading else {
            runtimes[id] = runtime
            return
        }
        // Selesai tanpa error: segmen lengkap kalau byte tersimpan
        // mencapai panjangnya (atau panjang tak diketahui dan task
        // selesai bersih, untuk file utuh tanpa Content-Length).
        let segment = record.segments[index]
        let length = Self.segmentLength(segment, totalBytes: record.totalBytes)
        let complete = length > 0 ? segment.received >= length : true
        if !complete {
            attemptRetryOrFail(
                id: id, index: index, runtime: &runtime,
                message: "Download terpotong: segmen \(index + 1) hanya menerima \(segment.received) dari \(length) byte."
            )
            return
        }
        var updated = record
        updated.segments[index].completed = true
        records[id] = updated
        persistRecord(id: id)
        if updated.segments.allSatisfy({ $0.completed }) {
            runtime.state = .verifying
            runtimes[id] = runtime
            publish()
            mergeParts(id: id)
        } else {
            runtimes[id] = runtime
            publish()
        }
    }

    /// Satu segmen gagal/terpotong: coba lagi dari byte terakhir yang
    /// tersimpan (bukan dari awal segmen), sampai batas retry. Segmen
    /// lain yang berjalan tidak dibatalkan; segmen yang sudah selesai
    /// tetap tersimpan. Baru kalau retry habis, download dinyatakan
    /// gagal dan pengguna bisa Lanjutkan manual.
    private func attemptRetryOrFail(id: UUID, index: Int, runtime: inout Runtime, message: String) {
        guard let record = records[id],
              record.segments.indices.contains(index),
              !record.segments[index].completed
        else {
            runtimes[id] = runtime
            return
        }
        let attempts = runtime.retryCounts[index, default: 0]
        if attempts < Self.maxSegmentRetries {
            runtime.retryCounts[index] = attempts + 1
            runtimes[id] = runtime
            if let retryTask = makeSegmentTask(id: id, index: index) {
                runtime.tasks[index] = retryTask
                runtimes[id] = runtime
                retryTask.resume()
            }
            publish()
            return
        }
        failItem(
            id: id, runtime: &runtime,
            message: message + " Segmen yang sudah selesai tersimpan — tekan Lanjutkan untuk mencoba lagi."
        )
    }

    private func failItem(id: UUID, runtime: inout Runtime, message: String) {
        cancelTasks(for: id, runtime: &runtime)
        runtime.state = .failed
        runtime.errorMessage = message
        runtimes[id] = runtime
        persistRecord(id: id)
        publish()
        startNextQueued()
    }

    /// Server mengabaikan Range: ubah catatan menjadi satu segmen
    /// utuh dan pakai task yang sedang berjalan sebagai sumber file
    /// lengkap. File part lama (berisi potongan Range) dihapus supaya
    /// tidak tercampur dengan byte file utuh.
    private func convertToWholeFile(id: UUID, currentTask: URLSessionDataTask, totalBytes: Int64) {
        guard var record = records[id], var runtime = runtimes[id] else { return }
        for (index, task) in runtime.tasks where task.taskIdentifier != currentTask.taskIdentifier {
            task.cancel()
        }
        closeHandles(runtime: &runtime)
        try? FileManager.default.removeItem(at: partsDirectory(for: record))
        record.rangesSupported = false
        if totalBytes > 0 {
            record.totalBytes = totalBytes
        }
        record.segments = [Segment(start: 0, end: -1, completed: false, received: 0)]
        records[id] = record
        currentTask.taskDescription = "\(id.uuidString)|0"
        runtime.tasks = [0: currentTask]
        runtime.expectedLengths = [:]
        runtimes[id] = runtime
        persistRecord(id: id)
    }

    // MARK: - Penyelesaian

    private func mergeParts(id: UUID) {
        guard let record = records[id], var runtime = runtimes[id] else { return }
        closeHandles(runtime: &runtime)
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
            DispatchQueue.main.async { [weak self] in
                BackgroundSupport.notifyIfBackground(
                    title: "LlamaChat", body: "Download \(record.fileName) selesai."
                )
                self?.onFinished?()
            }
            startNextQueued()
        } catch {
            runtime.state = .failed
            runtime.errorMessage = "Gagal menggabungkan file: \(error.localizedDescription)"
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
            let received = record.segments.reduce(Int64(0)) { partial, segment in
                if segment.completed {
                    return partial + Self.segmentLength(segment, totalBytes: record.totalBytes)
                }
                return partial + segment.received
            }
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
            // sisanya = byte tersimpan / panjang segmen.
            let fractions = record.segments.map { segment -> Double in
                if segment.completed { return 1 }
                let length = Self.segmentLength(segment, totalBytes: total)
                guard length > 0 else { return 0 }
                return min(1, Double(segment.received) / Double(length))
            }
            items.append(DownloadItem(
                id: id, url: url, fileName: record.fileName,
                state: runtime.state, progress: progress,
                receivedBytes: received, totalBytes: total,
                speedBytesPerSec: runtime.speedBytesPerSec,
                segmentsDone: record.segments.filter { $0.completed }.count,
                segmentCount: record.segments.count,
                activeSegments: runtime.tasks.count,
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

// MARK: - URLSessionDataDelegate (berjalan di workQueue)

extension ModelDownloadManager: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        handleResponse(task: dataTask, response: response, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handleData(task: dataTask, data: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handleCompletion(task: task, error: error)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier
        guard let identifier,
              let handler = backgroundCompletionHandlers.removeValue(forKey: identifier)
        else { return }
        DispatchQueue.main.async { handler() }
    }
}
