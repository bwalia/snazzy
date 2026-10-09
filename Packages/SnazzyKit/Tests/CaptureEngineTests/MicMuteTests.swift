@preconcurrency import AVFoundation
import Testing
@testable import CaptureEngine

@Suite(.serialized) struct MicMuteTests {
    /// 480 frames of 16-bit mono PCM at 48 kHz, all samples 1000.
    static func tone(at seconds: Double) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Int16](repeating: 1000, count: 480)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 960, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: 960,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 960)
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                             sampleCount: 480, presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
                                                             packetDescriptions: nil, sampleBufferOut: &out)
        return try #require(out)
    }

    static func bytes(_ b: CMSampleBuffer) -> [UInt8] {
        let data = CMSampleBufferGetDataBuffer(b)!
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(data))
        CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes.count, destination: &bytes)
        return bytes
    }

    @Test func mutedAudioIsSilenceWithTheSameTiming() throws {
        let tone = try Self.tone(at: 12.5)
        MicMute.isMuted = false
        #expect(Self.bytes(MicMute.apply(tone)).contains { $0 != 0 })
        MicMute.isMuted = true
        defer { MicMute.isMuted = false }
        let silent = MicMute.apply(tone)
        #expect(Self.bytes(silent).allSatisfy { $0 == 0 } && Self.bytes(silent).count == 960)
        #expect(CMSampleBufferGetNumSamples(silent) == 480)
        #expect(CMSampleBufferGetPresentationTimeStamp(silent) == CMSampleBufferGetPresentationTimeStamp(tone))
        // The original is untouched.
        #expect(Self.bytes(tone).contains { $0 != 0 })
    }
}
