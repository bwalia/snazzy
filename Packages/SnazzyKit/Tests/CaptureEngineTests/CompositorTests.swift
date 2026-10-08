import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

@Suite struct LipSyncTests {
    /// A camera picture that runs behind the sound is stamped earlier, so they line up.
    @Test func lateCameraIsStampedEarlier() {
        var profile = DeviceProfile.defaults(for: .camera)
        profile.videoDelayMs = 200
        let spec = CompositeSpec(layout: InsetLayout(), profile: profile)
        let now = CMTime(seconds: 10, preferredTimescale: 600)
        #expect(spec.syncedVideoTime(now, hasCamera: true).seconds == 9.8)
        #expect(spec.syncedVideoTime(now, hasCamera: false) == now)  // nothing to line up
        var bluetooth = spec
        bluetooth.profile.videoDelayMs = -150  // the sound is the late one
        #expect(abs(bluetooth.syncedVideoTime(now, hasCamera: true).seconds - 10.15) < 0.000_001)
    }
}

@Suite struct CompositorTests {
    let canvas = CGSize(width: 192, height: 108)
    let screen = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 384, height: 216))
    let camera = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))

    func spec(border: Double = 0, radius: Double = 0, corner: InsetCorner = .bottomRight) -> CompositeSpec {
        CompositeSpec(
            canvas: canvas,
            layout: InsetLayout(corner: corner, size: 0.5, margin: 0.1, borderWidth: border, cornerRadius: radius),
            profile: DeviceProfile(crop: InsetCrop(aspect: 16.0 / 9.0, zoom: 1)),
            borderColor: CIColor(red: 0, green: 1, blue: 0))
    }

    @Test func insetSitsInItsCorner() {
        let out = Compositor.compose(screen: screen, camera: camera, spec: spec())
        #expect(out.extent == CGRect(origin: .zero, size: canvas))
        // Inset 96×54 at bottom-right with a 10.8 px margin: x 85.2…181.2, y(top-left) 43.2…97.2.
        #expect(pixel(out, x: 130, yDown: 70) == (0, 0, 255))
        #expect(pixel(out, x: 40, yDown: 20) == (255, 0, 0))
        #expect(pixel(out, x: 186, yDown: 104) == (255, 0, 0))  // margin
        let topLeft = Compositor.compose(screen: screen, camera: camera, spec: spec(corner: .topLeft))
        #expect(pixel(topLeft, x: 30, yDown: 30) == (0, 0, 255))
        #expect(pixel(topLeft, x: 150, yDown: 80) == (255, 0, 0))
    }

    @Test func borderAndRoundedCorners() {
        // Border 10 px at 1080p = 1 px on this 108 px canvas; use 40 → 4 px.
        let out = Compositor.compose(screen: screen, camera: camera, spec: spec(border: 40, radius: 0.3))
        #expect(pixel(out, x: 83, yDown: 70) == (0, 255, 0))      // left border
        #expect(pixel(out, x: 130, yDown: 70) == (0, 0, 255))     // inside
        // The very corner of the outer box is outside the rounded border → screen shows.
        #expect(pixel(out, x: 82, yDown: 40) == (255, 0, 0))
    }

    @Test func screenIsLetterboxed() {
        let tall = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 200))
        let out = Compositor.compose(screen: tall, camera: nil, spec: spec())
        #expect(pixel(out, x: 96, yDown: 54) == (255, 0, 0))
        #expect(pixel(out, x: 5, yDown: 54) == (0, 0, 0))   // pillarbox
    }

    @Test func noScreenNoCameraIsBlack() {
        let out = Compositor.compose(screen: nil, camera: nil, spec: spec())
        #expect(pixel(out, x: 10, yDown: 10) == (0, 0, 0))
    }
}
