import AppKit
import CaptureEngine
import SnazzyCore
import SwiftUI

/// New Layout: make a recording again with the camera somewhere else, cropped
/// differently, with another background or lip sync, or in 4K, from its raw tracks.
struct RelayoutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: RecordingItem

    @State private var recording: Relayout.Recording?
    @State private var options: Relayout.Options?
    @State private var previewTime = 1.0
    @State private var preview: CGImage?
    @State private var error: String?
    @State private var saved: URL?

    private static let aspects: [(String, Double?)] = [("16:9", 16.0 / 9.0), ("4:3", 4.0 / 3.0), ("1:1", 1), ("9:16", 9.0 / 16.0), ("Whole picture", nil)]

    var body: some View {
        let dev = model.developer!
        VStack(alignment: .leading, spacing: 14) {
            Text("New Layout or Clip: \(item.id)").font(.title3.weight(.semibold))
            if let recording, let options {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 8) {
                        let aspect: CGFloat = options.resolution == .vertical ? 9 / 16 : 16 / 9
                        Group {
                            if let preview {
                                Image(decorative: preview, scale: 1).resizable().aspectRatio(aspect, contentMode: .fit)
                            } else {
                                Rectangle().fill(.quaternary).aspectRatio(aspect, contentMode: .fit).overlay(ProgressView())
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 440, maxHeight: 400)
                        Slider(value: $previewTime, in: 0...max(recording.duration, 0.1)) { Text("Preview at") }
                        Text("Preview at \(RecordingControls.format(previewTime)) of \(RecordingControls.format(recording.duration))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 440)
                    // A Form scrolls, so in a sheet it would shrink to almost nothing without a height.
                    Form { controls(recording, options) }
                        .formStyle(.grouped)
                        .frame(width: 360, height: 470)
                        .disabled(dev.relayoutProgress != nil)
                }
                footer(dev, options)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack { Spacer(); Button("Close") { dismiss() } }
            } else {
                ProgressView()
            }
        }
        .padding(20)
        .frame(minWidth: 850)
        .task {
            do {
                let r = try dev.relayoutSource(item)
                recording = r
                options = r.original
                previewTime = min(1, r.duration / 2)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: PreviewKey(options: options, time: previewTime)) {
            guard let recording, let options else { return }
            try? await Task.sleep(for: .milliseconds(120))  // settle while a slider moves
            guard !Task.isCancelled else { return }
            let image = model.capture.backgrounds.image(for: options.profile.background)
            preview = try? await Relayout.preview(recording, at: previewTime, options: options, backgroundImage: image)
        }
    }

    @ViewBuilder
    private func controls(_ recording: Relayout.Recording, _ options: Relayout.Options) -> some View {
        Section("Camera") {
            if recording.hasCamera {
                Toggle("Show camera", isOn: bind(\.showCamera))
            } else {
                Text("This recording has no camera.").foregroundStyle(.secondary)
            }
            if options.showCamera && recording.hasCamera {
                // Vertical puts the camera below the screen, so there's no corner or size to pick.
                if options.resolution != .vertical {
                    Picker("Corner", selection: bind(\.layout.corner)) {
                        ForEach(InsetCorner.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    LabeledSlider("Size", value: bind(\.layout.size), range: InsetLayout.sizeRange, format: "%.2f")
                    LabeledSlider("Border", value: bind(\.layout.borderWidth), range: 0...12, format: "%.0f px")
                    LabeledSlider("Rounding", value: bind(\.layout.cornerRadius), range: 0...0.5, format: "%.2f")
                }
                Picker("Shape", selection: bind(\.profile.crop.aspect)) {
                    ForEach(Self.aspects, id: \.0) { Text($0.0).tag($0.1) }
                }
                if options.profile.crop.aspect != nil {
                    LabeledSlider("Zoom", value: bind(\.profile.crop.zoom), range: InsetCrop.zoomRange, format: "%.2f")
                    LabeledSlider("Centre X", value: bind(\.profile.crop.centerX), range: 0...1, format: "%.2f")
                    LabeledSlider("Centre Y", value: bind(\.profile.crop.centerY), range: 0...1, format: "%.2f")
                }
                Picker("Rotation", selection: bind(\.profile.rotation)) {
                    Text("None").tag(InsetRotation.none)
                    Text("Left (90° anticlockwise)").tag(InsetRotation.left)
                    Text("Right (90° clockwise)").tag(InsetRotation.right)
                    Text("180°").tag(InsetRotation.upsideDown)
                }
                Picker("Background", selection: bind(\.profile.background)) {
                    Text("None").tag(CameraBackground.none)
                    Text("Blur").tag(CameraBackground.blur(strength: 0.6))
                    let recorded = recording.original.profile.background
                    if recorded != .none, recorded != .blur(strength: 0.6) {
                        Text("As recorded (\(model.capture.backgrounds.describe(recorded)))").tag(recorded)
                    }
                }
                LabeledSlider("Lip sync", value: bind(\.profile.videoDelayMs), range: DeviceProfile.videoDelayRange, format: "%.0f ms")
            }
        }
        Section("Output") {
            Picker("Format", selection: bind(\.resolution)) {
                Text("Landscape 1080p").tag(Relayout.Resolution.hd1080)
                Text("Landscape 4K").tag(Relayout.Resolution.uhd4K)
                Text("Vertical 9:16 (Shorts, Reels, TikTok)").tag(Relayout.Resolution.vertical)
            }
            Toggle("Only part of it", isOn: Binding {
                options.range != nil
            } set: { on in
                self.options?.range = on ? previewTime...min(previewTime + 30, recording.duration) : nil
                if on, let r = self.options?.range, r.upperBound - r.lowerBound < 1 {
                    self.options?.range = max(0, recording.duration - 30)...recording.duration
                }
            })
            if let range = options.range {
                LabeledSlider("Start", value: Binding { range.lowerBound } set: { v in
                    self.options?.range = min(v, range.upperBound - 1)...range.upperBound
                    previewTime = min(v, range.upperBound - 1)
                }, range: 0...max(recording.duration - 1, 0), format: "%.1f s")
                LabeledSlider("End", value: Binding { range.upperBound } set: { v in
                    self.options?.range = range.lowerBound...max(v, range.lowerBound + 1)
                    previewTime = max(v, range.lowerBound + 1)
                }, range: min(1, recording.duration)...recording.duration, format: "%.1f s")
                Text("\(RecordingControls.format(range.lowerBound))–\(RecordingControls.format(range.upperBound)), \(Int((range.upperBound - range.lowerBound).rounded())) s")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Back to the Recorded Layout") { self.options = recording.original }
        }
    }

    @ViewBuilder
    private func footer(_ dev: DeveloperController, _ options: Relayout.Options) -> some View {
        HStack(spacing: 10) {
            if let progress = dev.relayoutProgress {
                ProgressView(value: progress).frame(width: 260)
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { dev.cancelRelayout() }
            } else if let saved {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved \(saved.lastPathComponent)").lineLimit(1)
                Button("Open") { NSWorkspace.shared.open(saved) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            } else {
                Text("A new file is saved next to the recording; the original stays as it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.disabled(dev.relayoutProgress != nil)
            Button("Make New Version") { export(dev, options) }
                .keyboardShortcut(.defaultAction)
                .disabled(dev.relayoutProgress != nil)
        }
    }

    private func export(_ dev: DeveloperController, _ options: Relayout.Options) {
        error = nil
        saved = nil
        Task {
            do {
                saved = try await dev.relayout(item, options: options)
            } catch is CancellationError {
                error = "Cancelled. Nothing was saved."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<Relayout.Options, T>) -> Binding<T> {
        Binding { options![keyPath: keyPath] } set: { options![keyPath: keyPath] = $0 }
    }

    private struct PreviewKey: Equatable {
        var options: Relayout.Options?
        var time: Double
    }
}
