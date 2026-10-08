@preconcurrency import AVFoundation
import Foundation

/// Clap calibration for lip sync. While the user claps a few times in view of the
/// camera, find each clap's sound in the mic and the moment the hands meet in the
/// picture (fast motion that stops at once). How much later the picture shows it
/// is how far the camera runs behind the sound (`DeviceProfile.videoDelayMs`).
public enum SyncCalibration {
    public struct Result: Sendable, Equatable {
        /// Picture behind sound, in ms.
        public var delayMs: Double
        public var claps: Int
    }

    /// Onsets of short, loud sounds (claps), in seconds: `start` is the time of the first sample.
    public static func claps(in samples: [Float], sampleRate: Double, start: Double, window: Double = 0.005) -> [Double] {
        let n = max(Int(sampleRate * window), 1)
        guard samples.count >= n else { return [] }
        let envelope: [Float] = stride(from: 0, through: samples.count - n, by: n).map { i in
            var sum: Float = 0
            for s in samples[i..<i + n] { sum += s * s }
            return (sum / Float(n)).squareRoot()
        }
        guard let peak = envelope.max(), peak > 0.02 else { return [] }  // nothing loud at all
        let background = envelope.sorted()[envelope.count / 2]
        let threshold = max(background * 8, peak * 0.3)
        var out: [Double] = []
        for (k, e) in envelope.enumerated() where e >= threshold && (k == 0 || envelope[k - 1] < threshold) {
            let t = start + Double(k * n) / sampleRate
            if t - (out.last ?? -.infinity) >= 0.25 { out.append(t) }
        }
        return out
    }

    /// When moving hands stop at once (they met): the first frame after a motion peak
    /// whose motion is under half the peak. `motion` is (time, energy) per frame.
    public static func contacts(_ motion: [(time: Double, energy: Double)]) -> [Double] {
        guard motion.count > 2, let peak = motion.map(\.energy).max(), peak > 0 else { return [] }
        let background = motion.map(\.energy).sorted()[motion.count / 2]
        let threshold = max(background * 4, peak * 0.3)
        var out: [Double] = []
        for i in 1..<(motion.count - 1) {
            let e = motion[i].energy
            guard e >= threshold, e >= motion[i - 1].energy, e >= motion[i + 1].energy,
                  let j = (i + 1..<motion.count).first(where: { motion[$0].energy < e / 2 }),
                  motion[j].time - motion[i].time < 0.2 else { continue }
            if motion[j].time - (out.last ?? -.infinity) >= 0.25 { out.append(motion[j].time) }
        }
        return out
    }

    /// Pairs each clap with the hands meeting closest to it (from just before to well
    /// after) and takes the median difference. Nil with fewer than two pairs.
    public static func delay(claps: [Double], contacts: [Double]) -> Double? {
        let differences = claps.compactMap { clap in
            contacts.map { $0 - clap }.filter { $0 > -0.2 && $0 < 0.8 }.min { abs($0) < abs($1) }
        }
        guard differences.count >= 2 else { return nil }
        return differences.sorted()[differences.count / 2]
    }

    /// Brightness on a coarse grid of a BGRA picture, for frame-to-frame motion.
    static func luma(_ buffer: CVPixelBuffer, columns: Int = 48, rows: Int = 27) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out: [Float] = []
        out.reserveCapacity(columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                let o = ((2 * r + 1) * h / (2 * rows)) * rowBytes + ((2 * c + 1) * w / (2 * columns)) * 4
                out.append(0.114 * Float(p[o]) + 0.587 * Float(p[o + 1]) + 0.299 * Float(p[o + 2]))
            }
        }
        return out
    }
}

/// Listens to the inset camera and a mic for a few seconds of claps and works out
/// the lip-sync delay. Camera frames count from when they *arrive*: the recording
/// shows the newest frame that has arrived, so that's the delay to make up.
public final class SyncCalibrator: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var motion: [(time: Double, energy: Double)] = []
    private var previous: [Float]?
    private var samples: [Float] = []
    private var audioStart: Double?
    private var sampleRate: Double = 48_000
    private let micQueue = DispatchQueue(label: "com.snazzy.pro.sync-mic")

    override public init() {}

    public func run(camera: FrameReceiver, micID: String?, seconds: Double = 6) async throws -> SyncCalibration.Result {
        guard let mic = micID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            throw CaptureError("No microphone to listen with.")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: mic)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: micQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError("Can't listen with \(mic.localizedName).") }
        session.addInput(input)
        session.addOutput(output)
        let consumer = camera.addConsumer { [weak self] buffer in self?.frame(buffer) }
        session.startRunning()
        try? await Task.sleep(for: .seconds(seconds))
        session.stopRunning()
        camera.removeConsumer(consumer)

        let (motion, samples, start, rate) = lock.withLock { (self.motion, self.samples, self.audioStart, self.sampleRate) }
        let claps = SyncCalibration.claps(in: samples, sampleRate: rate, start: start ?? 0)
        guard let delay = SyncCalibration.delay(claps: claps, contacts: SyncCalibration.contacts(motion)) else {
            throw CaptureError(claps.count < 2
                ? "Heard \(claps.count) clap\(claps.count == 1 ? "" : "s"). Clap 3 times, loudly, a second apart."
                : "Couldn't see the claps. Clap with both hands clearly in the camera's view.")
        }
        return SyncCalibration.Result(delayMs: (delay * 1000).rounded(), claps: claps.count)
    }

    private func frame(_ buffer: CMSampleBuffer) {
        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard let pixels = CMSampleBufferGetImageBuffer(buffer), let luma = SyncCalibration.luma(pixels) else { return }
        lock.withLock {
            if let previous, previous.count == luma.count {
                var sum: Float = 0
                for i in luma.indices { sum += abs(luma[i] - previous[i]) }
                motion.append((arrival, Double(sum / Float(luma.count))))
            }
            previous = luma
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let floats = pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { Array(UnsafeBufferPointer(start: $0, count: length / 4)) }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let rate = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
        lock.withLock {
            if audioStart == nil {
                audioStart = time
                sampleRate = rate ?? 48_000
            }
            samples += floats
        }
    }
}
