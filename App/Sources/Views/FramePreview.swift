import CaptureEngine
import SnazzyCore
import SwiftUI

/// SwiftUI wrapper for the Metal preview of a feed after the inset transform.
struct FramePreview: NSViewRepresentable {
    let receiver: FrameReceiver
    let profile: DeviceProfile
    var interactive = true
    var onProfileChange: ((DeviceProfile) -> Void)?

    func makeNSView(context: Context) -> FramePreviewView {
        let view = FramePreviewView()
        update(view)
        return view
    }

    func updateNSView(_ view: FramePreviewView, context: Context) { update(view) }

    private func update(_ view: FramePreviewView) {
        if view.receiver !== receiver { view.receiver = receiver }
        if view.profile != profile { view.profile = profile }
        view.isInteractive = interactive
        view.onProfileChange = onProfileChange
    }
}

/// The inset preview for one feed: picture, status overlay and quick controls.
struct InsetPreviewContent: View {
    let feed: CameraFeed
    @Environment(CaptureController.self) private var capture
    var compact = false
    @State private var hovering = false

    var body: some View {
        let profile = capture.profile(for: feed.device.id, kind: feed.device.kind)
        ZStack(alignment: .bottom) {
            Color.black
            FramePreview(receiver: feed.receiver, profile: profile) { newProfile in
                capture.setProfile(newProfile, for: feed.device.id)
            }
            statusOverlay
            if hovering && !compact {
                controls(profile)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help("Drag to move the crop, scroll or pinch to zoom")
    }

    @ViewBuilder private var statusOverlay: some View {
        switch feed.state {
        case .live:
            EmptyView()
        default:
            VStack {
                Label(feed.state.description, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
                Spacer()
            }
        }
    }

    private var icon: String {
        switch feed.state {
        case .stalled, .disconnected, .noFrames: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        default: "hourglass"
        }
    }

    private func controls(_ profile: DeviceProfile) -> some View {
        HStack(spacing: 10) {
            Button {
                var p = profile
                p.rotation = p.rotation.nextClockwise
                capture.setProfile(p, for: feed.device.id)
            } label: { Image(systemName: "rotate.right") }
            .help("Rotate 90°")
            Button {
                var p = profile
                p.crop.aspect = p.crop.aspect == nil ? 16.0 / 9.0 : nil
                capture.setProfile(p, for: feed.device.id)
            } label: { Image(systemName: profile.crop.aspect == nil ? "crop" : "arrow.up.left.and.arrow.down.right") }
            .help(profile.crop.aspect == nil ? "Crop to 16:9" : "Fit whole picture")
            Button {
                capture.setProfile(.defaults(for: feed.device.kind), for: feed.device.id)
            } label: { Image(systemName: "arrow.counterclockwise") }
            .help("Reset crop and rotation")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
