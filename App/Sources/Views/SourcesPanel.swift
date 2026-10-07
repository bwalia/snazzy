import CaptureEngine
import SnazzyCore
import SwiftUI

/// Mic, capture source, inset camera with live preview, and inset layout.
struct SourcesPanel: View {
    @Environment(CaptureController.self) private var capture
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            MicSection()
            SourceSection()
            InsetDeviceSection()
            if capture.setup.insetDevice != nil {
                CropSection()
            }
            LayoutSection()
            RecordingPreviewSection()
            Section {
                Button("Show Diagnostics") { openWindow(id: "diagnostics") }
            }
        }
        .formStyle(.grouped)
        .task {
            await capture.catalog.refresh()
            capture.restoreInsetFeed()
        }
        .onAppear { capture.useScreen("sources-panel", true) }
        .onDisappear { capture.useScreen("sources-panel", false) }
    }
}

private struct MicSection: View {
    @Environment(CaptureController.self) private var capture

    var body: some View {
        Section("Microphone") {
            Picker("Microphone", selection: Binding(
                get: { capture.setup.mic?.uniqueID ?? "" },
                set: { id in _ = try? capture.selectMic(id) })
            ) {
                if capture.setup.mic == nil { Text("Choose…").tag("") }
                ForEach(capture.catalog.microphones) { mic in
                    Text(mic.isDefault ? "\(mic.name) (system default)" : mic.name).tag(mic.id)
                }
                if let mic = capture.setup.mic, !capture.catalog.microphones.contains(where: { $0.id == mic.uniqueID }) {
                    Text("\(mic.name) (disconnected)").tag(mic.uniqueID)
                }
            }
            if let warning = capture.micWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        }
    }
}

private struct SourceSection: View {
    @Environment(CaptureController.self) private var capture

    private enum Tag: Hashable { case none, display(UInt32), window(UInt32), slides }

    var body: some View {
        Section {
            Picker("Record", selection: Binding<Tag>(
                get: {
                    switch capture.setup.source {
                    case .display(let id, _)?: .display(id)
                    case .window(let id, _, _)?: .window(id)
                    case .slides?: .slides
                    case nil: .none
                    }
                },
                set: { tag in
                    switch tag {
                    case .display(let id): _ = try? capture.selectDisplay(String(id))
                    case .window(let id): Task { _ = try? await capture.selectWindow(String(id)) }
                    case .slides: capture.selectSlidesSource()
                    case .none: break
                    }
                })
            ) {
                if capture.setup.source == nil { Text("Choose…").tag(Tag.none) }
                Section("Displays") {
                    ForEach(capture.catalog.displays) { d in
                        Text("\(d.name) (\(d.width)×\(d.height))\(d.isMain ? ", main" : "")").tag(Tag.display(d.id))
                    }
                }
                if !capture.catalog.windows.isEmpty {
                    Section("Windows") {
                        ForEach(capture.catalog.windows) { w in
                            Text(w.title.isEmpty ? w.app : "\(w.app): \(w.title)").lineLimit(1).tag(Tag.window(w.id))
                        }
                    }
                }
                Text("Slides (full-screen slide window)").tag(Tag.slides)
                if case .window(let id, let app, let title)? = capture.setup.source,
                   !capture.catalog.windows.contains(where: { $0.id == id }) {
                    Text("\(app): \(title) (not open)").tag(Tag.window(id))
                }
            }
            if !capture.catalog.screenRecordingAllowed {
                HStack {
                    Label("Screen recording permission is needed to list windows and record the screen.",
                          systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { capture.catalog.requestScreenRecording() }
                }
            }
        } header: {
            HStack {
                Text("Capture source")
                Spacer()
                Button {
                    Task { await capture.catalog.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh devices, displays and windows")
            }
        }
    }
}

private struct InsetDeviceSection: View {
    @Environment(CaptureController.self) private var capture
    @State private var error: String?

    var body: some View {
        Section("Camera inset") {
            Picker("Inset camera", selection: Binding(
                get: { capture.setup.insetDevice?.uniqueID ?? "" },
                set: { id in
                    let device = (capture.catalog.iosDevices + capture.catalog.cameras).first { $0.id == id }
                    capture.setInsetDevice(device)
                })
            ) {
                Text("None").tag("")
                if !capture.catalog.iosDevices.isEmpty {
                    Section("iPad / iPhone (USB)") {
                        ForEach(capture.catalog.iosDevices) { Text($0.name).tag($0.id) }
                    }
                }
                Section("Cameras") {
                    ForEach(capture.catalog.cameras) { Text("\($0.name) (\($0.transport))").tag($0.id) }
                }
                if let inset = capture.setup.insetDevice,
                   !(capture.catalog.iosDevices + capture.catalog.cameras).contains(where: { $0.id == inset.uniqueID }) {
                    Text("\(inset.name) (not connected)").tag(inset.uniqueID)
                }
            }

            HStack {
                Button("Find iPad / iPhone") {
                    Task {
                        do {
                            error = nil
                            try await capture.selectInsetDevice("ios")
                        } catch let e {
                            error = e.localizedDescription
                        }
                    }
                }
                .disabled(capture.searchStatus != nil)
                if let status = capture.searchStatus {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            if let feed = capture.insetFeed {
                VStack(alignment: .leading, spacing: 6) {
                    InsetPreviewContent(feed: feed)
                        .aspectRatio(previewAspect(feed), contentMode: .fit)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        FeedStatusLine(feed: feed)
                        Spacer()
                        if capture.openPreviewIDs.contains(feed.device.id) {
                            Button("Close Preview") { capture.closePreview(deviceID: feed.device.id) }
                        } else {
                            Button("Open Floating Preview") { try? capture.openPreview(deviceID: feed.device.id) }
                        }
                    }
                }
            }
        }
    }

    private func previewAspect(_ feed: CameraFeed) -> CGFloat {
        guard let raw = feed.frameSize else { return 16.0 / 9.0 }
        let size = InsetGeometry.contentSize(raw: raw, profile: capture.profile(for: feed.device.id, kind: feed.device.kind))
        return size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }
}

struct FeedStatusLine: View {
    let feed: CameraFeed

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(feed.state.description)
            if let size = feed.frameSize, feed.state == .live {
                Text("· \(Int(size.width))×\(Int(size.height)) · \(Int(feed.framesPerSecond.rounded())) fps")
                    .foregroundStyle(.secondary)
            }
            if !feed.freezes.isEmpty {
                Text("· \(feed.freezes.count) freeze\(feed.freezes.count == 1 ? "" : "s")").foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }

    private var color: Color {
        switch feed.state {
        case .live: .green
        case .stalled, .disconnected, .waitingForDevice, .starting, .noFrames: .orange
        case .failed: .red
        case .idle: .gray
        }
    }
}

private struct CropSection: View {
    @Environment(CaptureController.self) private var capture

    private static let aspects: [(String, Double?)] = [("16:9", 16.0 / 9.0), ("4:3", 4.0 / 3.0), ("1:1", 1), ("9:16", 9.0 / 16.0), ("Whole picture", nil)]

    var body: some View {
        if let device = capture.setup.insetDevice {
            let profile = capture.profile(for: device.uniqueID, kind: device.kind)
            Section("Crop & rotation: \(device.name)") {
                Picker("Shape", selection: binding(profile, \.crop.aspect, device)) {
                    ForEach(Self.aspects, id: \.0) { Text($0.0).tag($0.1) }
                }
                Picker("Rotation", selection: binding(profile, \.rotation, device)) {
                    Text("None").tag(InsetRotation.none)
                    Text("Left (90° anticlockwise)").tag(InsetRotation.left)
                    Text("Right (90° clockwise)").tag(InsetRotation.right)
                    Text("180°").tag(InsetRotation.upsideDown)
                }
                if profile.crop.aspect != nil {
                    LabeledSlider("Zoom", value: binding(profile, \.crop.zoom, device), range: InsetCrop.zoomRange, format: "%.2f")
                    LabeledSlider("Centre X", value: binding(profile, \.crop.centerX, device), range: 0...1, format: "%.3f")
                    LabeledSlider("Centre Y", value: binding(profile, \.crop.centerY, device), range: 0...1, format: "%.3f")
                }
                Button("Reset to \(device.kind.rawValue) defaults") { capture.resetProfile(for: device) }
            }
        }
    }

    private func binding<T>(_ profile: DeviceProfile, _ keyPath: WritableKeyPath<DeviceProfile, T>, _ device: InsetDeviceSelection) -> Binding<T> {
        Binding {
            capture.profile(for: device.uniqueID, kind: device.kind)[keyPath: keyPath]
        } set: { newValue in
            var p = capture.profile(for: device.uniqueID, kind: device.kind)
            p[keyPath: keyPath] = newValue
            capture.setProfile(p, for: device.uniqueID)
        }
    }
}

private struct LayoutSection: View {
    @Environment(CaptureController.self) private var capture

    var body: some View {
        Section("Inset position") {
            Picker("Corner", selection: binding(\.corner)) {
                ForEach(InsetCorner.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledSlider("Size", value: binding(\.size), range: InsetLayout.sizeRange, format: "%.2f")
            LabeledSlider("Border", value: binding(\.borderWidth), range: 0...20, format: "%.0f px")
            LabeledSlider("Corner radius", value: binding(\.cornerRadius), range: 0...0.5, format: "%.2f")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<InsetLayout, T>) -> Binding<T> {
        Binding {
            capture.setup.layout[keyPath: keyPath]
        } set: { newValue in
            var layout = capture.setup.layout
            layout[keyPath: keyPath] = newValue
            capture.setLayout(layout)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text(String(format: format, value)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Exactly what will be recorded: the screen with the camera inset on top.
private struct RecordingPreviewSection: View {
    @Environment(CaptureController.self) private var capture

    var body: some View {
        Section("Preview of the recording") {
            CompositePreviewContent()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Circle().fill(capture.screen.state == .live ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(capture.screen.state == .live ? "Screen live\(capture.screen.frameSize.map { " · \(Int($0.width))×\(Int($0.height))" } ?? "") · output 1920×1080"
                     : capture.screen.state.description)
                    .font(.caption)
                Spacer()
                if capture.screen.state == .needsPermission {
                    Button("Allow Screen Recording…") { capture.catalog.requestScreenRecording() }
                }
                if capture.compositePreviewOpen {
                    Button("Close Floating Preview") { capture.closeCompositePreview() }
                } else {
                    Button("Open Floating Preview") { capture.openCompositePreview() }
                }
            }
            if capture.screen.state == .needsPermission {
                Text("After allowing Snazzy Pro in System Settings › Privacy & Security › Screen & System Audio Recording, quit and reopen the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Snazzy Pro's own windows (chat, previews, this panel) are left out of the recording; the Builder's result window is included.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
