import AppKit
import CaptureEngine
import CoreImage
import Foundation
import ImageIO
import Observation
import SnazzyCore
import UniformTypeIdentifiers

/// Background images: the built-ins plus pictures the user adds. Added images
/// are copied into the app (resized to at most 3840 px) so they keep working
/// even if the original file moves.
@MainActor @Observable
final class BackgroundLibrary {
    struct UserImage: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var file: String
    }

    private(set) var images: [UserImage] = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored private var cache: [String: CIImage] = [:]
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private let context = CIContext()

    static let maxDimension: CGFloat = 3840

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Snazzy Pro/Backgrounds", directoryHint: .isDirectory)) {
        self.directory = directory
        load()
    }

    private var indexURL: URL { directory.appending(path: "index.json") }

    private func load() {
        images = (try? JSONDecoder().decode([UserImage].self, from: Data(contentsOf: indexURL))) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(images).write(to: indexURL, options: .atomic)
    }

    /// Copies an image file into the library. Returns the new entry.
    @discardableResult
    func add(_ url: URL) throws -> UserImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.maxDimension,
              ] as CFDictionary)
        else { throw CaptureActionError(message: "\(url.lastPathComponent) isn't an image Snazzy Pro can read.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.prefix(8).lowercased()
        let file = "\(id).jpg"
        guard let dest = CGImageDestinationCreateWithURL(directory.appending(path: file) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CaptureActionError(message: "Couldn't save the image.") }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureActionError(message: "Couldn't save the image.") }
        let entry = UserImage(id: String(id), name: url.deletingPathExtension().lastPathComponent, file: file)
        images.append(entry)
        save()
        return entry
    }

    func delete(_ id: String) {
        guard let entry = images.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: entry.file))
        images.removeAll { $0.id == id }
        cache["image:\(id)"] = nil
        thumbnails["image:\(id)"] = nil
        save()
    }

    func rename(_ id: String, to name: String) {
        guard let i = images.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        images[i].name = name
        save()
    }

    /// The picture for a background, if it has one.
    func image(for background: CameraBackground) -> CIImage? {
        switch background {
        case .builtIn(let id):
            let key = "builtin:\(id)"
            if let c = cache[key] { return c }
            guard let kind = BuiltInBackground(rawValue: id), let img = BackgroundRenderer.builtIn(kind) else { return nil }
            cache[key] = img
            return img
        case .image(let id):
            let key = "image:\(id)"
            if let c = cache[key] { return c }
            guard let entry = images.first(where: { $0.id == id }),
                  let img = CIImage(contentsOf: directory.appending(path: entry.file)) else { return nil }
            cache[key] = img
            return img
        default:
            return nil
        }
    }

    /// Small preview for the picker.
    func thumbnail(for background: CameraBackground) -> NSImage? {
        let key: String
        switch background {
        case .builtIn(let id): key = "builtin:\(id)"
        case .image(let id): key = "image:\(id)"
        default: return nil
        }
        if let t = thumbnails[key] { return t }
        guard let img = image(for: background) else { return nil }
        let scale = 160 / max(img.extent.width, 1)
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
        let thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[key] = thumb
        return thumb
    }

    /// Finds a background by what someone might say: "blur", "none", a
    /// built-in name ("ocean"), an added image's name, or a hex colour.
    func resolve(_ query: String, strength: Double?) -> CameraBackground? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["none", "off", "no background", "remove"].contains(q) { return CameraBackground.none }
        if q.contains("blur") { return .blur(strength: strength ?? 0.6) }
        if q.hasPrefix("#"), CIColor(hex: q) != nil { return .color(hex: q.uppercased()) }
        if let kind = BuiltInBackground.allCases.first(where: {
            $0.rawValue.lowercased() == q || $0.displayName.lowercased() == q || $0.displayName.lowercased().contains(q)
        }) { return .builtIn(id: kind.rawValue) }
        if let entry = DeviceMatcher.match(query, in: images, id: \.id, name: \.name) { return .image(id: entry.id) }
        return nil
    }

    func describe(_ background: CameraBackground) -> String {
        switch background {
        case .none: "none"
        case .blur(let s): "blur (\(Int(s * 100))%)"
        case .color(let hex): "colour \(hex)"
        case .builtIn(let id): BuiltInBackground(rawValue: id)?.displayName ?? id
        case .image(let id): images.first { $0.id == id }?.name ?? "image"
        }
    }
}
