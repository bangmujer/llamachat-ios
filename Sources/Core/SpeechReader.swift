import AVFoundation
import Foundation

/// Pengaturan mode suara (Build 2). Satu sakelar: bila aktif, voice
/// note yang selesai ditranskripsi langsung dikirim dan jawaban
/// asisten dibacakan otomatis. Tombol speaker manual di tiap jawaban
/// tersedia apa pun pengaturan ini.
public enum VoiceModeSettings {
    private static let key = "llamachat.voiceModeEnabled"

    public static var voiceModeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Pembaca jawaban dengan suara (TTS on-device, Build 2).
///
/// Singleton `@MainActor` supaya `MessageBubble` dan `ChatViewModel`
/// berbagi satu `AVSpeechSynthesizer`: hanya satu jawaban yang
/// dibacakan dalam satu waktu, dan `stop()` dari mana pun menghentikan
/// pembacaan yang sedang berjalan. Suara Bahasa Indonesia bila tersedia
/// di perangkat, fallback Inggris. Teks dibatasi supaya pembacaan
/// tidak berjalan tanpa henti untuk jawaban yang sangat panjang.
@MainActor
public final class SpeechReader: NSObject, ObservableObject {
    public static let shared = SpeechReader()

    @Published public private(set) var isSpeaking = false
    @Published public private(set) var speakingMessageID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Bacakan `text` untuk pesan `messageID`. Kalau sudah membacakan
    /// pesan yang sama, panggil `toggle` saja (lihat di bawah).
    public func speak(_ text: String, messageID: UUID) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: String(cleaned.prefix(5_000)))
        utterance.voice = AVSpeechSynthesisVoice(language: "id-ID")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        speakingMessageID = messageID
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Satu ketukan: mulai kalau belum membacakan pesan ini, berhenti
    /// kalau sedang membacakannya.
    public func toggle(_ text: String, messageID: UUID) {
        if isSpeaking, speakingMessageID == messageID {
            stop()
        } else {
            speak(text, messageID: messageID)
        }
        Haptics.light()
    }

    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        speakingMessageID = nil
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        isSpeaking = false
        speakingMessageID = nil
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        isSpeaking = false
        speakingMessageID = nil
    }
}

/// Pemutar voice note terlampir (Build 2).
///
/// Singleton `@MainActor` seperti `SpeechReader`: satu audio yang
/// diputar dalam satu waktu; mengetuk audio lain menghentikan yang
/// sedang berjalan.
@MainActor
public final class AttachmentAudioPlayer: NSObject, ObservableObject {
    public static let shared = AttachmentAudioPlayer()

    @Published public private(set) var playingID: UUID?

    private var player: AVAudioPlayer?

    private override init() {
        super.init()
    }

    public func toggle(_ attachment: ChatAttachment) {
        if playingID == attachment.id {
            stop()
        } else {
            play(attachment)
        }
        Haptics.light()
    }

    private func play(_ attachment: ChatAttachment) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: attachment.fileURL)
            player.delegate = self
            self.player = player
            playingID = attachment.id
            player.play()
        } catch {
            playingID = nil
        }
    }

    public func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }
}

extension AttachmentAudioPlayer: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingID = nil
        self.player = nil
    }
}
