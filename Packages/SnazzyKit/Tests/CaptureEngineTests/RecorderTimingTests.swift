import AVFoundation
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

    /// Stereo PCM with a ramp in it, interleaved 16-bit or non-interleaved float (how mics deliver it).
    func stereoBuffer(at seconds: Double, float: Bool, frames: Int = 512) throws -> CMSampleBuffer {
        let bytes = float ? 4 : 2
        let flags = float ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
                          : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        let perFrame = UInt32(float ? bytes : bytes * 2)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: perFrame,
            mFramesPerPacket: 1, mBytesPerFrame: perFrame, mChannelsPerFrame: 2, mBitsPerChannel: UInt32(bytes * 8), mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let length = frames * bytes * 2
        var data = [UInt8](repeating: 0, count: length)
        for i in 0..<length { data[i] = UInt8(truncatingIfNeeded: i * 7) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length)
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), packetDescriptions: nil, sampleBufferOut: &buffer)
        return try #require(buffer)
    }

    func bytes(of buffer: CMSampleBuffer) -> [UInt8] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        var out = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: out.count, destination: &out)
        return out
    }

    @Test(arguments: [false, true]) func pcmCopyKeepsSamplesAndMovesTime(float: Bool) throws {
        let original = try stereoBuffer(at: 987.6, float: float)
        let copy = try #require(original.pcmCopy(at: CMTime(seconds: 3, preferredTimescale: 48_000)))
        #expect(abs(CMSampleBufferGetPresentationTimeStamp(copy).seconds - 3) < 1e-6)
        #expect(CMSampleBufferGetNumSamples(copy) == 512)
        #expect(abs(CMSampleBufferGetDuration(copy).seconds - 512.0 / 48_000) < 1e-6)
        #expect(bytes(of: copy) == bytes(of: original))
        let layout = CMAudioFormatDescriptionGetChannelLayout(CMSampleBufferGetFormatDescription(copy)!, sizeOut: nil)
        #expect(layout?.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_Stereo)
    }

    /// The composite's audio settings (AAC, mono, 48 kHz) accept the copies.
    @Test(arguments: [false, true]) func pcmCopiesEncodeToMonoAAC(float: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pcm-copy-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter.crashSafeMovie(url)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<100 {
            let copy = try #require(try stereoBuffer(at: 5000 + Double(i), float: float).pcmCopy(at: CMTime(value: CMTimeValue(i * 512), timescale: 48_000)))
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            #expect(input.append(copy), "\(writer.error.map(WriterError.describe) ?? "")")
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(writer.error.map(WriterError.describe) ?? "")")
    }

    @Test func writerErrorsShowTheirCodes() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12737),
        ])
        #expect(WriterError.describe(error) == "The operation could not be completed. (AVFoundationErrorDomain -11800, NSOSStatusErrorDomain -12737)")
    }
}
