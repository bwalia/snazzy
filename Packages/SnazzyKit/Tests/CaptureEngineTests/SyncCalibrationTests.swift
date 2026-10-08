import CoreVideo
import Foundation
import Testing
@testable import CaptureEngine

@Suite struct SyncCalibrationTests {
    /// Three claps in quiet room noise, 1 s apart.
    @Test func hearsClaps() {
        let rate = 48_000.0
        var generator = SystemRandomNumberGenerator()
        var samples = (0..<Int(rate * 4)).map { _ in Float.random(in: -0.004...0.004, using: &generator) }
        for clap in [1.0, 2.0, 3.0] {
            let at = Int(clap * rate)
            for i in 0..<480 { samples[at + i] = 0.8 * Float(1 - Double(i) / 480) * (i.isMultiple(of: 2) ? 1 : -1) }
        }
        let claps = SyncCalibration.claps(in: samples, sampleRate: rate, start: 100)
        #expect(claps.count == 3)
        for (found, real) in zip(claps, [101.0, 102.0, 103.0]) { #expect(abs(found - real) < 0.006) }
        #expect(SyncCalibration.claps(in: Array(samples[0..<Int(rate * 0.9)]), sampleRate: rate, start: 0).isEmpty)  // only noise
    }

    /// Hands speed up, then stop when they meet: that's where the clap is in the picture.
    @Test func seesHandsMeet() {
        var motion: [(time: Double, energy: Double)] = (0..<120).map { (100 + Double($0) / 30, 1) }
        for meet in [1.2, 2.2, 3.2] {
            let k = Int(meet * 30)
            for (offset, e) in zip(-4...0, [6.0, 14, 25, 40, 3]) { motion[k + offset].energy = e }
        }
        let contacts = SyncCalibration.contacts(motion)
        #expect(contacts.count == 3)
        for (found, real) in zip(contacts, [101.2, 102.2, 103.2]) { #expect(abs(found - real) < 0.04) }
    }

    @Test func delayIsTheMedianDifference() {
        let claps = [101.0, 102.0, 103.0]
        #expect(abs((SyncCalibration.delay(claps: claps, contacts: [101.2, 102.25, 103.19]) ?? 0) - 0.2) < 1e-9)
        // One clap seen is not enough to trust.
        #expect(SyncCalibration.delay(claps: claps, contacts: [101.2]) == nil)
        // A sound much later than any motion isn't paired.
        #expect(SyncCalibration.delay(claps: [101, 109], contacts: [101.1, 102.5]) == nil)
    }

    @Test func lumaOfASolidPicture() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 96, 54, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(pixels) * 54) { base[i] = 200 }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let luma = try #require(SyncCalibration.luma(pixels))
        #expect(luma.count == 48 * 27 && luma.allSatisfy { abs($0 - 200) < 0.5 })
    }
}
