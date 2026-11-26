import ActivityKit
import SwiftUI
import WidgetKit

/// Widget extension Live Activity download: Dynamic Island (iPhone
/// dengan pulau dinamis) + tampilan Lock Screen. Tidak ada logika
/// download di sini — semua state datang dari `DownloadActivityAttributes`
/// yang dikirim app utama lewat ActivityKit.
///
/// Satu activity aktif dalam satu waktu (download yang sedang berjalan
/// atau terjeda); app utama yang memulai, memperbarui, dan
/// mengakhirinya. Extension ini hanya menggambar.
@main
struct DownloadLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivityWidget()
    }
}

struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.percentText)
                        .font(.title3.bold())
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.fileName)
                            .lineLimit(1)
                            .font(.footnote)
                        ProgressView(value: context.state.progress)
                        Text(context.state.detailText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text(context.state.percentText)
                    .font(.caption.bold())
                    .monospacedDigit()
            } compactTrailing: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .frame(width: 20, height: 20)
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
            }
        }
    }

    private func lockScreenView(
        context: ActivityViewContext<DownloadActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                Text(context.state.fileName)
                    .lineLimit(1)
                    .font(.headline)
                Spacer()
                Text(context.state.percentText)
                    .font(.headline)
                    .monospacedDigit()
            }
            ProgressView(value: context.state.progress)
            Text(context.state.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
