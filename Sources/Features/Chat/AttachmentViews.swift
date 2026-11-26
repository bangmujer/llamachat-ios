import SwiftUI
import UIKit

/// Tampilan lampiran di dalam bubble pesan + chip lampiran tertunda
/// di atas composer (Build 2).
struct MessageAttachmentsView: View {
    let attachments: [ChatAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                switch attachment.kind {
                case .image:
                    StoredImageView(attachment: attachment)
                case .file:
                    fileRow(attachment)
                case .audio:
                    AudioAttachmentRow(attachment: attachment)
                }
            }
        }
    }

    private func fileRow(_ attachment: ChatAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(AttachmentStore.displaySize(attachment.byteCount))
                    .font(.caption)
                    .opacity(0.7)
            }
            Spacer()
            if attachment.isProcessing {
                ProgressView()
            }
        }
    }
}

/// Gambar lampiran dari file tersimpan, diperkecil supaya tidak
/// memakan memori penuh saat foto beresolusi tinggi.
private struct StoredImageView: View {
    let attachment: ChatAttachment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 120)
                    .overlay {
                        if attachment.isProcessing {
                            ProgressView()
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .task(id: attachment.storedFileName) {
            image = await Self.loadImage(for: attachment)
        }
    }

    private static func loadImage(for attachment: ChatAttachment) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let original = UIImage(contentsOfFile: attachment.fileURL.path) else { return nil }
            return downscaled(original, maxDimension: 1200)
        }.value
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Baris voice note: tombol putar/berhenti + durasi.
struct AudioAttachmentRow: View {
    let attachment: ChatAttachment
    @ObservedObject private var player = AttachmentAudioPlayer.shared

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle(attachment)
            } label: {
                Image(systemName: player.playingID == attachment.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice note")
                    .font(.subheadline)
                Text("\(Int(attachment.duration.rounded())) dtk • \(AttachmentStore.displaySize(attachment.byteCount))")
                    .font(.caption)
                    .opacity(0.7)
            }
            Spacer()
        }
    }
}

/// Chip lampiran yang menunggu dikirim, di atas composer. Ketuk `x`
/// untuk membatalkan lampiran (file-nya ikut dihapus).
struct PendingAttachmentsView: View {
    let attachments: [ChatAttachment]
    var onRemove: (ChatAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: attachment))
                        Text(attachment.fileName)
                            .font(.footnote)
                            .lineLimit(1)
                        if attachment.isProcessing {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hapus lampiran \(attachment.fileName)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
        }
    }

    private func icon(for attachment: ChatAttachment) -> String {
        switch attachment.kind {
        case .image: return "photo"
        case .file: return "doc.text"
        case .audio: return "mic"
        }
    }
}
