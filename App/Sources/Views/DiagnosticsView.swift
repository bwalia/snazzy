import CaptureEngine
import SwiftUI

/// Device events, stalls, dropped frames and feed health.
struct DiagnosticsView: View {
    @Environment(CaptureController.self) private var capture

    var body: some View {
        VStack(spacing: 0) {
            if !capture.feeds.feeds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(capture.feeds.feeds.values), id: \.device.id) { feed in
                        HStack {
                            Text(feed.device.name).font(.callout.weight(.medium))
                            FeedStatusLine(feed: feed)
                            Spacer()
                            Text("dropped \(feed.droppedFrames)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                Divider()
            }
            Table(capture.diagnostics.entries.reversed()) {
                TableColumn("Time") { e in
                    Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                }
                .width(80)
                TableColumn("") { e in
                    Image(systemName: e.level == .error ? "xmark.octagon.fill" : e.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(e.level == .error ? .red : e.level == .warning ? .orange : .secondary)
                }
                .width(20)
                TableColumn("Area", value: \.category).width(70)
                TableColumn("Event", value: \.message)
            }
        }
        .toolbar {
            Button("Clear") { capture.diagnostics.clear() }
        }
        .frame(minWidth: 560, minHeight: 300)
    }
}
