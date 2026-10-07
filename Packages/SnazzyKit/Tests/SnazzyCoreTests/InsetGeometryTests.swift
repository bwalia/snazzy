import CoreGraphics
import Foundation
import Testing
@testable import SnazzyCore

@Suite struct InsetGeometryTests {
    @Test func uprightSizeSwapsForQuarterTurns() {
        let raw = CGSize(width: 1080, height: 1920)
        #expect(InsetGeometry.uprightSize(raw, rotation: .left) == CGSize(width: 1920, height: 1080))
        #expect(InsetGeometry.uprightSize(raw, rotation: .right) == CGSize(width: 1920, height: 1080))
        #expect(InsetGeometry.uprightSize(raw, rotation: .upsideDown) == raw)
        #expect(InsetGeometry.uprightSize(raw, rotation: .none) == raw)
    }

    @Test func cropMatchesPrototypeMaths() {
        // iPad landscape 2732×2048 with the prototype's iPad defaults.
        let v = CGSize(width: 2732, height: 2048)
        let r = InsetGeometry.cropRect(upright: v, crop: DeviceProfile.defaults(for: .iPad).crop)
        let cw = min(2732.0, 2048.0 * 16 / 9) * 0.88  // 2404.16
        let ch = cw * 9 / 16
        #expect(abs(r.width - cw) < 0.001)
        #expect(abs(r.height - ch) < 0.001)
        #expect(abs(r.minX - (2732 * 0.485 - cw / 2)) < 0.001)
        #expect(abs(r.minY - (2048 * 0.42 - ch / 2)) < 0.001)
    }

    @Test func cropStaysInsideThePicture() {
        let v = CGSize(width: 1920, height: 1080)
        let r = InsetGeometry.cropRect(upright: v, crop: InsetCrop(aspect: 1, zoom: 0.5, centerX: 0, centerY: 1))
        #expect(r == CGRect(x: 0, y: 540, width: 540, height: 540))
        let full = InsetGeometry.cropRect(upright: v, crop: InsetCrop(aspect: nil, zoom: 0.3))
        #expect(full == CGRect(origin: .zero, size: v))
    }

    @Test func iPhoneSidewaysDefaults() {
        let profile = DeviceProfile.defaults(for: .iPhone)
        #expect(profile.rotation == .left)
        // Portrait iPhone frame 1206×2622 → upright 2622×1206.
        let size = InsetGeometry.contentSize(raw: CGSize(width: 1206, height: 2622), profile: profile)
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.0001)
        #expect(abs(size.width - min(2622, 1206 * 16 / 9.0) * 0.62) < 0.001)
    }

    @Test func insetFramePerCorner() {
        let canvas = CGSize(width: 1920, height: 1080)
        let layout = InsetLayout(corner: .bottomRight, size: 0.25, margin: 0.02)
        let f = InsetGeometry.insetFrame(canvas: canvas, contentAspect: 16.0 / 9.0, layout: layout)
        #expect(f.height == 270)
        #expect(f.width == 480)
        #expect(abs(f.maxX - (1920 - 21.6)) < 0.001)
        #expect(abs(f.maxY - (1080 - 21.6)) < 0.001)
        var tl = layout
        tl.corner = .topLeft
        let g = InsetGeometry.insetFrame(canvas: canvas, contentAspect: 1, layout: tl)
        #expect(abs(g.minX - 21.6) < 0.001 && abs(g.minY - 21.6) < 0.001 && g.width == 270)
    }

    @Test func rotationSuggestions() {
        #expect(InsetGeometry.suggestedRotation(kind: .iPhone, raw: CGSize(width: 1206, height: 2622)) == .left)
        #expect(InsetGeometry.suggestedRotation(kind: .iPhone, raw: CGSize(width: 2622, height: 1206)) == InsetRotation.none)
        #expect(InsetGeometry.suggestedRotation(kind: .iPad, raw: CGSize(width: 2048, height: 2732)) == InsetRotation.none)
        #expect(InsetGeometry.suggestedRotation(kind: .iPad, raw: .zero) == nil)
    }

    @Test func deviceKindDetection() {
        #expect(DeviceKind.detect(name: "Alex’s iPhone", modelID: "iOS Device") == .iPhone)
        #expect(DeviceKind.detect(name: "iPad", modelID: "iOS Device") == .iPad)
        #expect(DeviceKind.detect(name: "iPhone Camera", modelID: "Continuity") == .camera)
    }

    @Test func insetChanges() throws {
        #expect(InsetChanges.parseAspect("4:3") == .some(4.0 / 3.0))
        #expect(InsetChanges.parseAspect("fit") == .some(nil))
        #expect(InsetChanges.parseAspect("wide") == nil)

        var layout = InsetLayout()
        var profile = DeviceProfile.defaults(for: .iPad)
        var changes = InsetChanges()
        changes.corner = .topLeft
        changes.size = 2  // clamped
        changes.aspect = .some(nil)
        changes.zoom = 0.5
        changes.rotation = .right
        changes.apply(layout: &layout, profile: &profile)
        #expect(layout.corner == .topLeft)
        #expect(layout.size == InsetLayout.sizeRange.upperBound)
        #expect(profile.crop.aspect == nil)
        #expect(profile.crop.zoom == 0.5)
        #expect(profile.crop.centerX == 0.485)  // untouched
        #expect(profile.rotation == .right)
    }

    @Test func captureSetupRoundTrip() throws {
        var setup = CaptureSetup(
            mic: MicSelection(uniqueID: "uid", name: "USB Audio"),
            source: .display(id: 2, name: "LG UltraFine"),
            insetDevice: InsetDeviceSelection(uniqueID: "ipad", name: "iPad", kind: .iPad))
        setup.profiles["ipad"] = DeviceProfile(crop: InsetCrop(zoom: 0.7), rotation: .left, videoDelayMs: 150)
        let decoded = try JSONDecoder().decode(CaptureSetup.self, from: JSONEncoder().encode(setup))
        #expect(decoded == setup)
        #expect(decoded.profile(for: "ipad", kind: .iPad).videoDelayMs == 150)
        #expect(decoded.profile(for: "other", kind: .iPhone) == .defaults(for: .iPhone))
        #expect(try JSONDecoder().decode(CaptureSetup.self, from: Data("{}".utf8)) == CaptureSetup())
    }
}
