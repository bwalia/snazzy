import AVFoundation
import AppKit
import SnazzyCore
import SwiftUI

/// Your recordings, newest first, with what you can do to each one.
struct RecordingsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dev = model.developer!
        VStack(spacing: 0) {
            HStack {
                if let busy = dev.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(dev.recordings.count) recording\(dev.recordings.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dev.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { NSWorkspace.shared.open(dev.folder) } label: { Image(systemName: "folder") }.help("Show the Recordings folder")
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            if dev.recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "record.circle",
                                       description: Text("Press Record in the toolbar, or ask: “start recording”."))
            } else {
                List(dev.recordings) { item in
                    RecordingRow(item: item)
                }
            }
        }
        .onAppear { dev.refresh() }
    }
}

struct RecordingRow: View {
    @Environment(AppModel.self) private var model
    let item: RecordingItem
    @State private var duration: Double?
    @State private var error: String?

    var body: some View {
        let dev = model.developer!
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: item.id.contains("(") ? "scissors" : "film")
                    .foregroundStyle(.secondary)
                Text(item.id).font(.callout.weight(.medium)).lineLimit(1).textSelection(.enabled)
                Spacer()
                Text(meta).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                Button("Open") { NSWorkspace.shared.open(item.url) }
                if dev.settings.trimEnabled {
                    Button("Trim…") { dev.openTrimmer(item) }
                }
                DeveloperRowActions(item: item, error: $error)
                Spacer()
                Button { dev.reveal(item) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
        .task(id: item.id) {
            duration = try? await AVURLAsset(url: item.url).load(.duration).seconds
        }
    }

    private var meta: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        let d = duration.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "–"
        return "\(d) · \(size) · \(item.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Buttons added by later developer features (captions, summary, share).
struct DeveloperRowActions: View {
    let item: RecordingItem
    @Binding var error: String?
    var body: some View { EmptyView() }
}
