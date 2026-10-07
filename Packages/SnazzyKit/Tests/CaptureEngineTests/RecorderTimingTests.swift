import CoreMedia
import Foundation
import Testing
@testable import CaptureEngine

@Suite struct RecorderTimingTests {
    /// A 1024-sample mono PCM buffer at the given time.
    func audioBuffer(at seconds: Double) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 2048, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: 2048, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 2048)
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: 1024,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), packetDescriptions: nil, sampleBufferOut: &buffer)
        return try #require(buffer)
    }

    @Test func retimingShiftsPresentationTime() throws {
        let original = try audioBuffer(at: 1234.5)
        let shifted = try #require(original.retimed(to: CMTime(seconds: 2, preferredTimescale: 48_000)))
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(shifted).seconds - 2) < 1e-6)
        #expect(CMSampleBufferGetNumSamples(shifted) == 1024)
        #expect(abs(CMSampleBufferGetDuration(shifted).seconds - 1024.0 / 48_000) < 1e-6)
    }

    @Test func audioLevelOfSilenceIsZero() throws {
        #expect(AudioLevel.rms(try audioBuffer(at: 0)) == 0)
    }
}
