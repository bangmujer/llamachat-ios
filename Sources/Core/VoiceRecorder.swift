import AVFoundation
import Foundation
import Speech

/// Hasil satu rekaman voice note (Build 2).
public struct VoiceRecordingResult: Equatable {
    public let id = UUID()
    public let transcription: String
    public let audioData: Data
    public let duration: TimeInterval
}

/// Perekam voice note + transkripsi on-device/iOS (Build 2).
///
/// Alur: `startRecording()` (minta izin mikrofon) → rekam AAC (m4a) →
/// `stopAndTranscribe()` → transkripsi lewat `SFSpeechRecognizer`
/// (locale id-ID, fallback en-US) → hasil diterbitkan di `completed`
/// untuk ditangani `ChatView`. Transkripsi memakai pengenalan ucapan
/// iOS: kalau model bahasa on-device belum terunduh, iOS bisa memakai
/// jaringan — itu satu-satunya bagian Build 2 yang tidak sepenuhnya
/// offline, dan hanya terjadi saat pengguna merekam voice note.
///
/// Berjalan di MainActor; tidak ada state yang dibagi dengan engine.
@MainActor
public final class VoiceRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var elapsed: TimeInterval = 0
    /// Pesan error terakhir untuk ditampilkan sebagai alert oleh View.
    @Published public var alertMessage: String?
    /// Hasil rekaman yang selesai ditranskripsi. View mengosongkannya
    /// setelah menangani (pola `onChange`).
    @Published public var completed: VoiceRecordingResult?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var ticker: Task<Void, Never>?
    private var startDate: Date?
    private var recognitionTask: SFSpeechRecognitionTask?

    public init() {}

    public func startRecording() {
        guard !isRecording, !isTranscribing else { return }
        Task {
            let micGranted = await requestMicrophonePermission()
            guard micGranted else {
                alertMessage = "Izin mikrofon ditolak. Aktifkan di Pengaturan iPhone → LlamaChat → Mikrofon."
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
                try session.setActive(true)
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("voice-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.record()
                self.recorder = recorder
                recordingURL = url
                startDate = Date()
                elapsed = 0
                isRecording = true
                ticker = Task { @MainActor [weak self] in
                    while let self, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if let startDate {
                            self.elapsed = Date().timeIntervalSince(startDate)
                        }
                    }
                }
                Haptics.light()
            } catch {
                alertMessage = "Tidak bisa mulai merekam: \(error.localizedDescription)"
            }
        }
    }

    public func stopAndTranscribe() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        ticker?.cancel()
        ticker = nil
        isRecording = false
        let duration = elapsed
        elapsed = 0
        guard let url = recordingURL else { return }
        recordingURL = nil
        isTranscribing = true
        Task {
            defer {
                isTranscribing = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try? FileManager.default.removeItem(at: url)
            }
            let audioData = (try? Data(contentsOf: url)) ?? Data()
            let transcription = await transcribe(url: url)
            if audioData.isEmpty {
                alertMessage = "Rekaman kosong, tidak ada audio yang tersimpan."
                return
            }
            completed = VoiceRecordingResult(
                transcription: transcription.trimmingCharacters(in: .whitespacesAndNewlines),
                audioData: audioData,
                duration: duration
            )
            Haptics.success()
        }
    }

    public func cancelRecording() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        ticker?.cancel()
        ticker = nil
        isRecording = false
        elapsed = 0
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Izin & transkripsi

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func transcribe(url: URL) async -> String {
        guard await requestSpeechAuthorization() else {
            alertMessage = "Izin pengenalan ucapan ditolak. Aktifkan di Pengaturan iPhone → LlamaChat → Pengenalan Ucapan."
            return ""
        }
        for localeID in ["id-ID", "en-US"] {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
                  recognizer.isAvailable else { continue }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                var resumed = false
                recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal, !resumed {
                        resumed = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if error != nil, !resumed {
                        resumed = true
                        continuation.resume(returning: "")
                    }
                }
            }
            recognitionTask = nil
            return text
        }
        alertMessage = "Pengenalan ucapan tidak tersedia di perangkat ini saat ini."
        return ""
    }
}
