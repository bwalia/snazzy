import AppKit
import CaptureEngine
import SnazzyCore
import SwiftUI
import UniformTypeIdentifiers

/// Background for the inset camera: none, blur, built-ins, the user's images or a colour.
struct BackgroundSection: View {
    @Environment(CaptureController.self) private var capture
    @State private var dropTargeted = false
    @State private var error: String?
    @State private var renaming: BackgroundLibrary.UserImage?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)]

    var body: some View {
        if let device = capture.setup.insetDevice {
            let current = capture.profile(for: device.uniqueID, kind: device.kind).background
            Section {
                LazyVGrid(columns: columns, spacing: 10) {
                    Tile(title: "None", selected: current == .none) {
                        Image(systemName: "person.crop.rectangle").font(.title2).foregroundStyle(.secondary)
                    } action: { set(.none) }

                    Tile(title: "Blur", selected: isBlur(current)) {
                        ZStack {
                            LinearGradient(colors: [.purple.opacity(0.5), .orange.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .blur(radius: 6)
                            Image(systemName: "person.fill").font(.title2).foregroundStyle(.white)
                        }
                    } action: { set(.blur(strength: blurStrength(current) ?? 0.6)) }

                    ForEach(BuiltInBackground.allCases, id: \.self) { kind in
                        let bg = CameraBackground.builtIn(id: kind.rawValue)
                        Tile(title: kind.displayName, selected: current == bg) { thumb(bg) } action: { set(bg) }
                    }

                    ForEach(capture.backgrounds.images) { image in
                        let bg = CameraBackground.image(id: image.id)
                        Tile(title: image.name, selected: current == bg) { thumb(bg) } action: { set(bg) }
                            .contextMenu {
                                Button("Rename…") { newName = image.name; renaming = image }
                                Button("Delete", role: .destructive) {
                                    if current == bg { set(.none) }
                                    capture.backgrounds.delete(image.id)
                                }
                            }
                    }

                    Tile(title: "Add Image…", selected: false) {
                        Image(systemName: "plus").font(.title2).foregroundStyle(.secondary)
                    } action: { pickImages() }

                    ColorTile(current: current) { hex in set(.color(hex: hex)) }
                }
                .padding(.vertical, 4)
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            Task { @MainActor in addAndUse(url) }
                        }
                    }
                    return true
                }

                if let strength = blurStrength(current) {
                    LabeledSlider("Blur strength", value: Binding(get: { strength }, set: { set(.blur(strength: $0)) }),
                                  range: 0...1, format: "%.2f")
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("Separates you from your background on this Mac (Vision person segmentation). Applies to previews and recordings; raw camera tracks are kept unchanged. Drop images here to add them.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Background: \(device.name)")
            }
            .sheet(item: $renaming) { image in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rename background").font(.headline)
                    TextField("Name", text: $newName).frame(width: 260)
                    HStack {
                        Spacer()
                        Button("Cancel") { renaming = nil }
                        Button("Rename") { capture.backgrounds.rename(image.id, to: newName); renaming = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
            }
        }
    }

    private func isBlur(_ bg: CameraBackground) -> Bool { blurStrength(bg) != nil }

    private func blurStrength(_ bg: CameraBackground) -> Double? {
        if case .blur(let s) = bg { return s }
        return nil
    }

    private func set(_ bg: CameraBackground) {
        do { try capture.setBackground(bg); error = nil } catch let e { error = e.localizedDescription }
    }

    @ViewBuilder private func thumb(_ bg: CameraBackground) -> some View {
        if let image = capture.backgrounds.thumbnail(for: bg) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Color.gray.opacity(0.3)
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose background images"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addAndUse(url) }
    }

    private func addAndUse(_ url: URL) {
        do {
            let entry = try capture.backgrounds.add(url)
            set(.image(id: entry.id))
        } catch let e {
            error = e.localizedDescription
        }
    }
}

/// One square choice in the background grid.
private struct Tile<Content: View>: View {
    let title: String
    let selected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                            lineWidth: selected ? 3 : 1))
                Text(title).font(.caption2).lineLimit(1).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// A colour well tile.
private struct ColorTile: View {
    let current: CameraBackground
    let onPick: (String) -> Void
    @State private var color: Color = .init(red: 0.11, green: 0.13, blue: 0.24)

    var body: some View {
        let selected: Bool = { if case .color = current { true } else { false } }()
        VStack(spacing: 4) {
            ColorPicker("", selection: Binding(get: { color }, set: { color = $0; onPick(Self.hex($0)) }), supportsOpacity: false)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 8).fill(color))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                        lineWidth: selected ? 3 : 1))
            Text("Colour").font(.caption2).foregroundStyle(selected ? .primary : .secondary)
        }
        .onAppear {
            if case .color(let hex) = current, let c = CIColor(hex: hex) {
                color = Color(red: c.red, green: c.green, blue: c.blue)
            }
        }
    }

    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}
