import CaptureEngine
import SnazzyCore
import SwiftUI

/// Mic, capture source, inset camera with live preview, and inset layout.
struct SourcesPanel: View {
    @Environment(CaptureController.self) private var capture
    @Environment(\.openWindow) private var openWindow

    /// Panel width at which previews move into their own large column.
    static let wideWidth: CGFloat = 860

    /// Hides the settings column so the previews get the whole panel.
    @AppStorage("SnazzyPro.sourcesSettingsHidden") private var settingsHidden = false

    var body: some View {
        GeometryReader { geo in
            if settingsHidden || geo.size.width >= Self.wideWidth {
                // Wide (or settings hidden): previews grow with the window, settings on the right.
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .top) {
                                PreviewHeader()
                                settingsToggle
                            }
                            RecordingPreviewBlock(maxHeight: max(240, geo.size.height - (capture.insetFeed == nil ? 140 : 380)))
                            if capture.insetFeed != nil {
                                Text("Camera").font(.headline)
                                // The camera needs far less room than the screen.
                                CameraPreviewBlock(maxHeight: min(200, max(140, geo.size.height * 0.22)))
                            }
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: .infinity)
                    if !settingsHidden {
                        Divider()
                        controls(showsPreviews: false)
                            .frame(width: min(460, max(380, geo.size.width * 0.34)))
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        settingsToggle
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                    controls(showsPreviews: true)
                }
            }
        }
        .task {
            await capture.catalog.refresh()
            capture.restoreInsetFeed()
        }
        .onAppear { capture.useScreen("sources-panel", true) }
        .onDisappear { capture.useScreen("sources-panel", false) }
    }

    private var settingsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { settingsHidden.toggle() }
        } label: {
            Label(settingsHidden ? "Show Settings" : "Hide Settings", systemImage: "sidebar.right")
        }
        .help(settingsHidden ? "Show the mic, source and camera settings" : "Hide the settings to give the previews the whole panel")
    }

    private func controls(showsPreviews: Bool) -> some View {
        Form {
            if showsPreviews { RecordingPreviewSection() }
            MicSection()
            SourceSection()
            InsetDeviceSection(showsPreview: showsPreviews)
            if capture.setup.insetDevice != nil {
                BackgroundSection()
                CropSection()
            }
            LayoutSection()
            Section {
                Button("Show Diagnostics") { openWindow(id: "diagnostics") }
            }
        }
        .formStyle(.grouped)
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
                Label("Windows appear here once screen recording is allowed (see the preview above).",
                      systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
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
    var showsPreview = true
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
            .disabled(capture.recorder.isActive)
            .help(capture.recorder.isActive ? "The camera can't change while recording." : "")

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

            if showsPreview, capture.insetFeed != nil {
                CameraPreviewBlock(maxHeight: 260)
            }
        }
    }
}

/// The inset camera's live preview in a fixed 16:9 frame (the picture is
/// letterboxed inside), so crop and zoom changes never resize the layout.
struct CameraPreviewBlock: View {
    @Environment(CaptureController.self) private var capture
    let maxHeight: CGFloat?

    var body: some View {
        if let feed = capture.insetFeed {
            VStack(alignment: .leading, spacing: 6) {
                InsetPreviewContent(feed: feed)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: maxHeight.map { $0 * 16 / 9 } ?? .infinity, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    FeedStatusLine(feed: feed)
                    Spacer()
                    if capture.openPreviewIDs.contains(feed.device.id) {
                        Button("Close Floating Preview") { capture.closePreview(deviceID: feed.device.id) }
                    } else {
                        Button("Open Floating Preview") { try? capture.openPreview(deviceID: feed.device.id) }
                    }
                }
                .frame(maxWidth: maxHeight.map { $0 * 16 / 9 } ?? .infinity)
            }
        }
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
    @State private var calibrating = false
    @State private var calibration: String?

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
                LabeledSlider("Lip sync", value: binding(profile, \.videoDelayMs, device), range: DeviceProfile.videoDelayRange, format: "%.0f ms")
                HStack {
                    Button(calibrating ? "Listening: clap 3 times…" : "Calibrate with Claps") { calibrate() }
                        .disabled(calibrating || capture.recorder.isActive)
                    if let calibration { Text(calibration).font(.caption).foregroundStyle(.secondary) }
                }
                Text("If your voice comes before your lips move, move this right (an iPad by cable is often 150–250 ms late; left for a Bluetooth mic). Or calibrate: clap 3 times, a second apart, with your hands in view.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Reset to \(device.kind.rawValue) defaults") { capture.resetProfile(for: device) }
            }
        }
    }

    private func calibrate() {
        calibrating = true
        calibration = nil
        Task {
            defer { calibrating = false }
            do {
                let r = try await capture.calibrateLipSync()
                calibration = "Set to \(Int(r.delayMs)) ms (\(r.claps) claps)."
            } catch {
                calibration = error.localizedDescription
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

/// Exactly what will be recorded (screen + camera inset), or the screen alone.
enum PreviewMode: String, CaseIterable { case recording = "Recording", screen = "Screen only" }

/// "Preview" title with the Recording / Screen only switch.
private struct PreviewHeader: View {
    @AppStorage("SnazzyPro.previewMode") private var mode = PreviewMode.recording

    var body: some View {
        HStack {
            Text("Preview").font(.headline)
            Spacer()
            Picker("", selection: $mode) {
                ForEach(PreviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// In the narrow (one-column) layout, the preview is the first form section.
private struct RecordingPreviewSection: View {
    var body: some View {
        Section {
            RecordingPreviewBlock(maxHeight: 340)
        } header: {
            PreviewHeader()
        }
    }
}

/// What will be recorded (screen + inset), or the screen alone; grows with
/// the available width when `maxHeight` is nil.
struct RecordingPreviewBlock: View {
    @Environment(CaptureController.self) private var capture
    @AppStorage("SnazzyPro.previewMode") private var mode = PreviewMode.recording
    let maxHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !capture.catalog.screenRecordingAllowed || capture.screen.state == .needsPermission {
                PermissionBlock()
            } else {
                Group {
                    if mode == .recording {
                        CompositePreviewContent()
                    } else {
                        ScreenOnlyPreview()
                    }
                }
                .aspectRatio(mode == .recording ? 16.0 / 9.0 : screenAspect, contentMode: .fit)
                .frame(maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                HStack {
                    Circle().fill(capture.screen.state == .live ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(statusText).font(.caption)
                    Spacer()
                    if capture.compositePreviewOpen {
                        Button("Close Floating Preview") { capture.closeCompositePreview() }
                    } else {
                        Button("Open Floating Preview") { capture.openCompositePreview() }
                    }
                }
                Text("Snazzy Pro's own windows (chat, previews, this panel) are left out of the recording; the Builder's result window is included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var screenAspect: CGFloat {
        guard let s = capture.screen.frameSize, s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }

    private var statusText: String {
        guard capture.screen.state == .live else {
            return capture.screenSource == nil ? "Choose a display or window" : capture.screen.state.description
        }
        let size = capture.screen.frameSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? ""
        return "Screen live · \(size)" + (mode == .recording ? " · records at 1920×1080" : "")
    }
}

/// The screen alone, as captured.
private struct ScreenOnlyPreview: NSViewRepresentable {
    @Environment(CaptureController.self) private var capture

    func makeNSView(context: Context) -> ImagePreviewView {
        let view = ImagePreviewView()
        let screen = capture.screen
        view.provider = { [weak screen] in
            guard let frame = screen?.receiver.latest else { return nil }
            return (frame.image, frame.sequence)
        }
        return view
    }

    func updateNSView(_ view: ImagePreviewView, context: Context) {}
}

/// Explains and fixes missing screen-recording permission.
private struct PermissionBlock: View {
    @Environment(CaptureController.self) private var capture

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Snazzy Pro needs Screen Recording permission to show and record your screen.", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.callout.weight(.medium))
            Text("1. Click Open System Settings and switch on Snazzy Pro under Screen & System Audio Recording.\n2. Click Quit & Reopen (macOS only applies the permission after a restart).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Open System Settings") {
                    capture.catalog.requestScreenRecording()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Quit & Reopen") { AppRelaunch.relaunch() }
                Button("Check Again") { Task { await capture.catalog.refreshScreenContent(); await capture.updateScreenFeed() } }
            }
        }
        .padding(.vertical, 4)
    }
}
