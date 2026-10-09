@preconcurrency import AVFoundation
import Foundation

/// One switch that mutes the mic everywhere it's captured: the recording, the
/// live room and streams. Voice Mode turns it on while the assistant speaks, so
/// its voice (from the speakers) isn't recorded and it doesn't hear itself.
/// Muted audio is replaced by silence with the same timing, so tracks stay in sync.
public enum MicMute {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var muted = false

    public static var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// The buffer as captured, or silence in its place while muted.
    public static func apply(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
        isMuted ? (silentCopy(of: buffer) ?? buffer) : buffer
    }

    /// Same format, sample count and timing; every byte zero (silence for PCM).
    public static func silentCopy(of buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let data = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let length = CMBlockBufferGetDataLength(data)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(buffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
            packetDescriptions: nil, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
