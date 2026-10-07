import CoreImage
import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

@Suite struct ScreenReaderTests {
    @Test func readingOrder() {
        let lines = [
            ScreenReader.Line(text: "b", box: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.04)),
            ScreenReader.Line(text: "c", box: CGRect(x: 0.0, y: 0.3, width: 0.2, height: 0.04)),
            ScreenReader.Line(text: "a", box: CGRect(x: 0.0, y: 0.11, width: 0.2, height: 0.04)),
        ]
        #expect(ScreenReader.order(lines).map(\.text) == ["a", "b", "c"])
    }

    @Test func zoomRegionCoversTheMatchAndFollowingLines() throws {
        let lines = [
            ScreenReader.Line(text: "$ swift build", box: CGRect(x: 0.02, y: 0.10, width: 0.2, height: 0.03)),
            ScreenReader.Line(text: "error: cannot find 'Foo' in scope", box: CGRect(x: 0.02, y: 0.60, width: 0.4, height: 0.03)),
            ScreenReader.Line(text: "    at main.swift:12", box: CGRect(x: 0.04, y: 0.64, width: 0.3, height: 0.03)),
        ]
        let r = try #require(ScreenReader.zoomRegion(for: "Error:", in: lines, imageAspect: 16.0 / 10.0))
        #expect(r.contains(CGPoint(x: 0.2, y: 0.615)))
        #expect(r.contains(CGPoint(x: 0.2, y: 0.655)))
        #expect(r.minX >= 0 && r.maxX <= 1 && r.minY >= 0 && r.maxY <= 1)
        #expect(r.width >= 0.35)
        // On a 16:10 screen, the zoom box is 16:9 in pixels.
        #expect(abs((r.width * 16) / (r.height * 10) - 16.0 / 9.0) < 0.01)
        #expect(ScreenReader.zoomRegion(for: "nothing", in: lines, imageAspect: 1.6) == nil)
    }

    @Test func compositorZoomsIntoTheScreen() {
        // Screen: left half red, right half blue. Zoom on the right half → all blue.
        let screen = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
            .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: CIImage.empty()])
        let blue = CIImage(color: .blue).cropped(to: CGRect(x: 80, y: 0, width: 80, height: 90))
        let image = blue.composited(over: screen)
        var spec = CompositeSpec(canvas: CGSize(width: 160, height: 90), layout: InsetLayout(), profile: .defaults(for: .camera))
        spec.screenZoom = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let out = Compositor.compose(screen: image, camera: nil, spec: spec)
        #expect(pixel(out, x: 80, yDown: 45) == (0, 0, 255))
        spec.screenZoom = nil
        #expect(pixel(Compositor.compose(screen: image, camera: nil, spec: spec), x: 20, yDown: 45) == (255, 0, 0))
    }
}
