import CoreImage
import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

@Suite struct BackgroundTests {
    let size = CGRect(x: 0, y: 0, width: 200, height: 100)
    var camera: CIImage { CIImage(color: .red).cropped(to: size) }
    /// Person on the left half (white), background on the right (black).
    var mask: CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
            .composited(over: CIImage(color: .black).cropped(to: size))
    }

    @Test func colourReplacesOnlyTheBackground() {
        let out = BackgroundRenderer.render(camera: camera, mask: mask, background: .color(hex: "#00FF00"), image: nil)
        #expect(out.extent == size)
        #expect(pixel(out, x: 20, yDown: 50) == (255, 0, 0))   // person stays
        #expect(pixel(out, x: 180, yDown: 50) == (0, 255, 0))  // background replaced
    }

    @Test func imageIsAspectFilled() {
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        let out = BackgroundRenderer.render(camera: camera, mask: mask, background: .image(id: "x"), image: blue)
        #expect(pixel(out, x: 190, yDown: 5) == (0, 0, 255))
        #expect(BackgroundRenderer.aspectFill(blue, into: size).extent == size)
    }

    @Test func noneAndMissingImageLeaveCameraUnchanged() {
        let cam = camera
        #expect(BackgroundRenderer.render(camera: cam, mask: mask, background: .none, image: nil) === cam)
        let out = BackgroundRenderer.render(camera: camera, mask: mask, background: .builtIn(id: "ocean"), image: nil)
        #expect(pixel(out, x: 180, yDown: 50) == (255, 0, 0))
    }

    @Test func blurKeepsSizeAndPerson() {
        let out = BackgroundRenderer.render(camera: camera, mask: mask, background: .blur(strength: 0.5), image: nil)
        #expect(out.extent == size)
        #expect(pixel(out, x: 20, yDown: 50) == (255, 0, 0))
    }

    @Test func builtInsRender() {
        for kind in BuiltInBackground.allCases {
            let image = BackgroundRenderer.builtIn(kind, size: CGSize(width: 64, height: 36))
            #expect(image?.extent.size == CGSize(width: 64, height: 36), "\(kind)")
        }
    }

    @Test func hexColours() {
        #expect(CIColor(hex: "#FF4D5E")?.red == 1)
        #expect(CIColor(hex: "nope") == nil)
    }

    @Test func profileDecodesWithoutBackground() throws {
        let old = #"{"crop":{"aspect":1.7777,"zoom":0.88,"centerX":0.485,"centerY":0.42},"rotation":"none","videoDelayMs":0}"#
        let p = try JSONDecoder().decode(DeviceProfile.self, from: Data(old.utf8))
        #expect(p.background == .none)
        var q = p
        q.background = .blur(strength: 0.6)
        #expect(try JSONDecoder().decode(DeviceProfile.self, from: JSONEncoder().encode(q)) == q)
    }

    @Test func inactiveEffectPassesThrough() {
        let effect = BackgroundEffect()
        let cam = camera
        #expect(!effect.isActive)
        #expect(effect.apply(cam) === cam)
        effect.configure(.blur(strength: 0.5), image: nil)
        #expect(effect.isActive)
        #expect(effect.apply(cam) === cam)  // no mask yet → unchanged
    }
}
