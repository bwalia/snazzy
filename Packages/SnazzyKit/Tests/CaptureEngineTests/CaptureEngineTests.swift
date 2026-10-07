import CoreImage
import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

/// 4×2 test image (y-down description): top-left red, top-right green,
/// bottom-left blue, bottom-right white. Each quadrant is 2×1 pixels.
func quadrants() -> CIImage {
    let w: CGFloat = 4, h: CGFloat = 2
    func square(_ c: CIColor, x: CGFloat, yDown: CGFloat) -> CIImage {
        // Core Image is y-up.
        CIImage(color: c).cropped(to: CGRect(x: x, y: h - yDown - 1, width: 2, height: 1))
    }
    return square(.red, x: 0, yDown: 0)
        .composited(over: square(.green, x: 2, yDown: 0))
        .composited(over: square(.blue, x: 0, yDown: 1))
        .composited(over: square(.white, x: 2, yDown: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

/// Colour at (x, yDown) of an image whose extent is at the origin.
func pixel(_ image: CIImage, x: Int, yDown: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    var bytes = [UInt8](repeating: 0, count: 4)
    let y = Int(image.extent.height) - yDown - 1
    context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
    return (bytes[0], bytes[1], bytes[2])
}

@Suite struct FrameTransformTests {
    @Test func leftRotationIsCounterClockwise() {
        // ffmpeg transpose=2: the top-left corner ends up bottom-left.
        let out = FrameTransform.rotated(quadrants(), .left)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 2, height: 4))
        #expect(pixel(out, x: 0, yDown: 3) == (255, 0, 0))   // red: was top-left
        #expect(pixel(out, x: 0, yDown: 0) == (0, 255, 0))   // green: was top-right
        #expect(pixel(out, x: 1, yDown: 3) == (0, 0, 255))   // blue: was bottom-left
    }

    @Test func rightRotationIsClockwise() {
        let out = FrameTransform.rotated(quadrants(), .right)
        #expect(pixel(out, x: 1, yDown: 0) == (255, 0, 0))   // red: top-right
        #expect(pixel(out, x: 0, yDown: 0) == (0, 0, 255))   // blue: top-left
    }

    @Test func cropUsesTopLeftCoordinates() {
        // Square crop of the top-left 1×1… region: aspect 2:1, zoom 0.5 → 2×1 box at the top-left.
        let profile = DeviceProfile(crop: InsetCrop(aspect: 2, zoom: 0.5, centerX: 0, centerY: 0))
        let out = FrameTransform.apply(quadrants(), profile: profile)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(pixel(out, x: 0, yDown: 0) == (255, 0, 0))
        #expect(pixel(out, x: 1, yDown: 0) == (255, 0, 0))
    }

    @Test func rotateThenCrop() {
        let profile = DeviceProfile(crop: InsetCrop(aspect: 2, zoom: 1, centerX: 0.5, centerY: 1), rotation: .left)
        // Upright 2×4; widest 2:1 box is 2×1, centred at the bottom → red/blue row.
        let out = FrameTransform.apply(quadrants(), profile: profile)
        #expect(out.extent.size == CGSize(width: 2, height: 1))
        #expect(pixel(out, x: 0, yDown: 0) == (255, 0, 0))
        #expect(pixel(out, x: 1, yDown: 0) == (0, 0, 255))
    }
}

@Suite struct DeviceMatcherTests {
    struct Item { let id: String; let name: String }
    let items = [
        Item(id: "AppleUSBAudioEngine:C-Media:USB Advanced Audio Device:2013:2", name: "USB Advanced Audio Device"),
        Item(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
        Item(id: "iPad-1", name: "Alex’s iPad"),
    ]

    func find(_ q: String) -> String? { DeviceMatcher.match(q, in: items, id: \.id, name: \.name)?.name }

    @Test func matching() {
        #expect(find("BuiltInMicrophoneDevice") == "MacBook Pro Microphone")
        #expect(find("usb advanced audio device") == "USB Advanced Audio Device")
        #expect(find("USB") == "USB Advanced Audio Device")
        #expect(find("my USB mic") == "USB Advanced Audio Device")
        #expect(find("macbook microphone") == "MacBook Pro Microphone")
        #expect(find("ipad") == "Alex’s iPad")
        #expect(find("Yeti") == nil)
        #expect(find("  ") == nil)
    }
}
