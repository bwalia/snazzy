import CoreGraphics
import Foundation

/// How a device picture is turned upright before cropping.
/// `left` turns it 90° counter-clockwise (ffmpeg `transpose=2`), for an iPhone
/// held sideways whose Camera app stays portrait.
public enum InsetRotation: String, Codable, CaseIterable, Sendable {
    case none
    case left
    case right
    case upsideDown

    /// Counter-clockwise angle in degrees.
    public var degrees: Double {
        switch self {
        case .none: 0
        case .left: 90
        case .right: -90
        case .upsideDown: 180
        }
    }

    public var swapsAxes: Bool { self == .left || self == .right }

    /// The next rotation clockwise (for a "rotate" button).
    public var nextClockwise: InsetRotation {
        switch self {
        case .none: .right
        case .right: .upsideDown
        case .upsideDown: .left
        case .left: .none
        }
    }
}

/// The part of the (upright) device picture shown in the inset.
public struct InsetCrop: Codable, Hashable, Sendable {
    /// Width / height of the crop box; nil = fit the whole picture (no crop).
    public var aspect: Double?
    /// Fraction of the largest box of that aspect that is kept (smaller = tighter).
    public var zoom: Double
    /// Centre of the box, 0…1 from the left / top.
    public var centerX: Double
    public var centerY: Double

    public init(aspect: Double? = 16.0 / 9.0, zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.aspect = aspect
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
    }

    public static let zoomRange = 0.1...1.0

    /// Clamped to valid ranges.
    public var normalized: InsetCrop {
        var c = self
        c.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        c.centerX = min(max(centerX, 0), 1)
        c.centerY = min(max(centerY, 0), 1)
        if let a = aspect, !(a.isFinite && a > 0.1 && a < 10) { c.aspect = 16.0 / 9.0 }
        return c
    }
}

public enum DeviceKind: String, Codable, Sendable {
    case iPad
    case iPhone
    case camera

    /// iOS screen devices report modelID "iOS Device"; the name says which kind.
    public static func detect(name: String, modelID: String) -> DeviceKind {
        let lower = name.lowercased()
        if modelID == "iOS Device" {
            return lower.contains("iphone") ? .iPhone : .iPad
        }
        return .camera
    }
}

/// What replaces the area behind the person in a camera picture.
public enum CameraBackground: Codable, Hashable, Sendable {
    /// The camera picture as it is.
    case none
    /// Blur behind the person; strength 0…1.
    case blur(strength: Double)
    /// A solid colour, "#RRGGBB".
    case color(hex: String)
    /// One of the built-in backgrounds (see `BuiltInBackground`).
    case builtIn(id: String)
    /// An image the user added to the background library.
    case image(id: String)

    public var isActive: Bool { self != .none }
}

/// Backgrounds that ship with the app (drawn in code, any resolution).
public enum BuiltInBackground: String, CaseIterable, Sendable {
    case spotlight, ink, studioGrey, warmStudio, ocean, sunset, bokeh

    public var displayName: String {
        switch self {
        case .spotlight: "Spotlight"
        case .ink: "Ink"
        case .studioGrey: "Studio grey"
        case .warmStudio: "Warm studio"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .bokeh: "Bokeh"
        }
    }
}

/// Per-device crop, rotation, background and video delay.
public struct DeviceProfile: Codable, Hashable, Sendable {
    public var crop: InsetCrop
    public var rotation: InsetRotation
    /// Lip sync: how far this device's picture runs behind the sound, in ms (an iPad
    /// over USB or Continuity Camera can be 100–250 ms late). Negative when the sound
    /// is the late one, e.g. a Bluetooth mic. Video frames are stamped earlier by this.
    public var videoDelayMs: Double
    public static let videoDelayRange: ClosedRange<Double> = -500...1000
    /// Background replacement or blur behind the person.
    public var background: CameraBackground

    public init(crop: InsetCrop, rotation: InsetRotation = .none, videoDelayMs: Double = 0, background: CameraBackground = .none) {
        self.crop = crop
        self.rotation = rotation
        self.videoDelayMs = videoDelayMs
        self.background = background
    }

    // Tolerant decoding: profiles saved before backgrounds existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decode(InsetCrop.self, forKey: .crop)
        rotation = try c.decodeIfPresent(InsetRotation.self, forKey: .rotation) ?? .none
        videoDelayMs = try c.decodeIfPresent(Double.self, forKey: .videoDelayMs) ?? 0
        background = (try? c.decodeIfPresent(CameraBackground.self, forKey: .background)) ?? CameraBackground.none
    }

    /// Defaults from the prototype: they crop out the Camera app's buttons and
    /// sit slightly above centre so heads aren't cut off.
    public static func defaults(for kind: DeviceKind) -> DeviceProfile {
        switch kind {
        case .iPad:
            DeviceProfile(crop: InsetCrop(zoom: 0.88, centerX: 0.485, centerY: 0.42))
        case .iPhone:
            DeviceProfile(crop: InsetCrop(zoom: 0.62, centerX: 0.45, centerY: 0.47), rotation: .left)
        case .camera:
            DeviceProfile(crop: InsetCrop(zoom: 1, centerX: 0.5, centerY: 0.45))
        }
    }
}

public enum InsetCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var displayName: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

/// Where the inset sits on the output canvas.
public struct InsetLayout: Codable, Hashable, Sendable {
    public var corner: InsetCorner
    /// Inset height as a fraction of the canvas height.
    public var size: Double
    /// Gap to the canvas edges as a fraction of the canvas height.
    public var margin: Double
    /// Border width in output pixels at 1080p (scaled with the canvas).
    public var borderWidth: Double
    /// Corner radius as a fraction of the inset height.
    public var cornerRadius: Double

    public init(corner: InsetCorner = .bottomRight, size: Double = 0.28, margin: Double = 0.025,
                borderWidth: Double = 3, cornerRadius: Double = 0.06) {
        self.corner = corner
        self.size = size
        self.margin = margin
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
    }

    public static let sizeRange = 0.05...0.6

    public var normalized: InsetLayout {
        var l = self
        l.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        l.margin = min(max(margin, 0), 0.2)
        l.borderWidth = min(max(borderWidth, 0), 40)
        l.cornerRadius = min(max(cornerRadius, 0), 0.5)
        return l
    }
}

public enum InsetGeometry {
    /// Picture size after rotation.
    public static func uprightSize(_ raw: CGSize, rotation: InsetRotation) -> CGSize {
        rotation.swapsAxes ? CGSize(width: raw.height, height: raw.width) : raw
    }

    /// Crop box in upright pixels, top-left origin (same maths as the prototype's
    /// ffmpeg crop): the widest box of the aspect, scaled by zoom, centred on
    /// (centerX, centerY) and kept inside the picture.
    public static func cropRect(upright v: CGSize, crop: InsetCrop) -> CGRect {
        let c = crop.normalized
        guard let ar = c.aspect, v.width > 0, v.height > 0 else { return CGRect(origin: .zero, size: v) }
        let cw = min(v.width, v.height * ar) * c.zoom
        let ch = cw / ar
        let x = min(max(v.width * c.centerX - cw / 2, 0), v.width - cw)
        let y = min(max(v.height * c.centerY - ch / 2, 0), v.height - ch)
        return CGRect(x: x, y: y, width: cw, height: ch)
    }

    /// Size of the inset content (after rotation and crop) for a raw frame size.
    public static func contentSize(raw: CGSize, profile: DeviceProfile) -> CGSize {
        cropRect(upright: uprightSize(raw, rotation: profile.rotation), crop: profile.crop).size
    }

    /// Inset frame on a canvas, top-left origin, for content of the given aspect.
    public static func insetFrame(canvas: CGSize, contentAspect: Double, layout: InsetLayout) -> CGRect {
        let l = layout.normalized
        let h = canvas.height * l.size
        let w = h * (contentAspect > 0 ? contentAspect : 16.0 / 9.0)
        let m = canvas.height * l.margin
        let x: Double = (l.corner == .topLeft || l.corner == .bottomLeft) ? m : canvas.width - w - m
        let y: Double = (l.corner == .topLeft || l.corner == .topRight) ? m : canvas.height - h - m
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Best guess at the rotation from the frame shape. The iPhone Camera app
    /// stays portrait, so a portrait iPhone frame usually means a phone held
    /// sideways; an iPad rotates its own screen. Returns nil when unsure.
    public static func suggestedRotation(kind: DeviceKind, raw: CGSize) -> InsetRotation? {
        guard raw.width > 0, raw.height > 0 else { return nil }
        switch kind {
        case .iPhone: return raw.height > raw.width ? .left : InsetRotation.none
        case .iPad, .camera: return InsetRotation.none
        }
    }
}

public struct MicSelection: Codable, Hashable, Sendable {
    public var uniqueID: String
    /// Kept so the same mic can be found again if its ID changes (USB port).
    public var name: String

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

public struct InsetDeviceSelection: Codable, Hashable, Sendable {
    public var uniqueID: String
    public var name: String
    public var kind: DeviceKind

    public init(uniqueID: String, name: String, kind: DeviceKind) {
        self.uniqueID = uniqueID
        self.name = name
        self.kind = kind
    }
}

public enum CaptureSourceSelection: Codable, Hashable, Sendable {
    case display(id: UInt32, name: String)
    case window(id: UInt32, app: String, title: String)
    /// The app's own full-screen slide window (phase 5).
    case slides
}

/// What will be recorded. Persisted until projects (.snazzy packages) take over.
public struct CaptureSetup: Codable, Hashable, Sendable {
    public var mic: MicSelection?
    public var source: CaptureSourceSelection?
    public var insetDevice: InsetDeviceSelection?
    public var layout: InsetLayout
    /// Per-device profiles keyed by device unique ID.
    public var profiles: [String: DeviceProfile]
    /// On title slides the camera inset grows to this size (fraction of the picture
    /// height), and shrinks back on other slides; nil = off.
    public var titleSlideInsetSize: Double?
    public static let titleSlideSizeRange = 0.3...InsetLayout.sizeRange.upperBound

    public init(mic: MicSelection? = nil, source: CaptureSourceSelection? = nil,
                insetDevice: InsetDeviceSelection? = nil, layout: InsetLayout = InsetLayout(),
                profiles: [String: DeviceProfile] = [:]) {
        self.mic = mic
        self.source = source
        self.insetDevice = insetDevice
        self.layout = layout
        self.profiles = profiles
    }

    public func profile(for deviceID: String, kind: DeviceKind) -> DeviceProfile {
        profiles[deviceID] ?? .defaults(for: kind)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mic = try c.decodeIfPresent(MicSelection.self, forKey: .mic)
        source = try c.decodeIfPresent(CaptureSourceSelection.self, forKey: .source)
        insetDevice = try c.decodeIfPresent(InsetDeviceSelection.self, forKey: .insetDevice)
        layout = try c.decodeIfPresent(InsetLayout.self, forKey: .layout) ?? InsetLayout()
        profiles = try c.decodeIfPresent([String: DeviceProfile].self, forKey: .profiles) ?? [:]
        titleSlideInsetSize = try c.decodeIfPresent(Double.self, forKey: .titleSlideInsetSize)
    }
}

public struct CaptureSetupStore: Sendable {
    public static let key = "SnazzyPro.captureSetup.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> CaptureSetup {
        guard let data = defaults.data(forKey: Self.key) else { return CaptureSetup() }
        return (try? JSONDecoder().decode(CaptureSetup.self, from: data)) ?? CaptureSetup()
    }

    public func save(_ setup: CaptureSetup) {
        if let data = try? JSONEncoder().encode(setup) { defaults.set(data, forKey: Self.key) }
    }
}

/// Changes requested by `set_inset` (or the UI); nil fields are left alone.
public struct InsetChanges: Equatable, Sendable {
    public var corner: InsetCorner?
    public var size: Double?
    public var borderWidth: Double?
    public var cornerRadius: Double?
    /// .some(nil) = fit whole picture.
    public var aspect: Double??
    public var zoom: Double?
    public var centerX: Double?
    public var centerY: Double?
    public var rotation: InsetRotation?
    public var background: CameraBackground?
    public var videoDelayMs: Double?

    public init() {}

    /// Parses aspect strings like "16:9", "4:3", "1:1", "9:16" or "fit".
    public static func parseAspect(_ s: String) -> Double?? {
        if s.lowercased() == "fit" { return .some(nil) }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return .some(parts[0] / parts[1])
    }

    public func apply(layout: inout InsetLayout, profile: inout DeviceProfile) {
        if let corner { layout.corner = corner }
        if let size { layout.size = size }
        if let borderWidth { layout.borderWidth = borderWidth }
        if let cornerRadius { layout.cornerRadius = cornerRadius }
        if let aspect { profile.crop.aspect = aspect }
        if let zoom { profile.crop.zoom = zoom }
        if let centerX { profile.crop.centerX = centerX }
        if let centerY { profile.crop.centerY = centerY }
        if let rotation { profile.rotation = rotation }
        if let background { profile.background = background }
        if let videoDelayMs {
            profile.videoDelayMs = min(max(videoDelayMs, DeviceProfile.videoDelayRange.lowerBound), DeviceProfile.videoDelayRange.upperBound)
        }
        layout = layout.normalized
        profile.crop = profile.crop.normalized
    }
}
