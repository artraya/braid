import Foundation
import AudioToolbox

/// Transcodes a CAF Track to 16kHz mono FLAC for upload (SPEC Architecture:
/// "The Job transcodes each Track to FLAC before upload to cut transfer size").
public enum Transcoder {
    public static func toFLAC(_ input: URL) throws -> URL {
        let output = input.deletingPathExtension().appendingPathExtension("flac")
        try? FileManager.default.removeItem(at: output)

        var inFile: ExtAudioFileRef?
        try checkOS(ExtAudioFileOpenURL(input as CFURL, &inFile), "open \(input.lastPathComponent)")
        defer { if let inFile { ExtAudioFileDispose(inFile) } }

        var pcm = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        try checkOS(ExtAudioFileSetProperty(
            inFile!, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm), "set read format")

        var flac = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatFLAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var outFile: ExtAudioFileRef?
        try checkOS(ExtAudioFileCreateWithURL(
            output as CFURL, kAudioFileFLACType, &flac, nil,
            AudioFileFlags.eraseFile.rawValue, &outFile), "create \(output.lastPathComponent)")
        defer { if let outFile { ExtAudioFileDispose(outFile) } }
        try checkOS(ExtAudioFileSetProperty(
            outFile!, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm), "set write format")

        let framesPerChunk: UInt32 = 32_768
        var buffer = [Int16](repeating: 0, count: Int(framesPerChunk))
        while true {
            var frames = framesPerChunk
            let done: Bool = try buffer.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(raw.count),
                        mData: raw.baseAddress))
                try checkOS(ExtAudioFileRead(inFile!, &frames, &abl), "read chunk")
                if frames == 0 { return true }
                abl.mBuffers.mDataByteSize = frames * 2
                try checkOS(ExtAudioFileWrite(outFile!, frames, &abl), "write chunk")
                return false
            }
            if done { break }
        }
        return output
    }
}
