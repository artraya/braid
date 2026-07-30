import Foundation
import AudioToolbox

/// Writes one mono Track to a CAF file (16-bit PCM at 16kHz) via ExtAudioFile,
/// which performs sample-rate conversion from the device rate and flushes to
/// disk on its own thread (`ExtAudioFileWriteAsync`), keeping the real-time
/// callback free of disk and conversion work. CAF tolerates truncation, so a
/// crash mid-write loses only the unflushed tail (R2).
final class TrackWriter: @unchecked Sendable {
    private var file: ExtAudioFileRef?
    private(set) var framesWritten: Int64 = 0
    let deviceRate: Float64

    init(url: URL, deviceRate: Float64) throws {
        self.deviceRate = deviceRate
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var ref: ExtAudioFileRef?
        try checkOS(ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileCAFType, &fileFormat, nil,
            AudioFileFlags.eraseFile.rawValue, &ref), "create CAF \(url.lastPathComponent)")
        self.file = ref

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try checkOS(ExtAudioFileSetProperty(
            ref!, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat),
            "set client format")
        // Prime the async write machinery before the first real-time write.
        try checkOS(ExtAudioFileWriteAsync(ref!, 0, nil), "prime async write")
    }

    /// Real-time safe: hands `frames` mono Float32 samples to the async writer
    /// (which copies them). Returns without blocking on disk.
    func writeAsync(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard let file, frames > 0 else { return }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples)))
        _ = ExtAudioFileWriteAsync(file, UInt32(frames), &abl)
        framesWritten += Int64(frames)
    }

    /// Seconds of audio handed to the writer, in recorded-audio time.
    var duration: TimeInterval { TimeInterval(framesWritten) / deviceRate }

    func close() {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }

    deinit { close() }
}
