import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Sums the lane wavs into one stereo track, in order, a chunk at a time.
/// Streaming rather than loading: an hour of two float lanes is several
/// gigabytes in memory and there is no reason to hold any of it.
final class Mixer: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    private static let chunk: AVAudioFrameCount = 4096

    private final class Source {
        let file: AVAudioFile
        let converter: AVAudioConverter
        var silenceLeft: AVAudioFrameCount
        let gain: Float
        var drained = false

        init?(lane: Mux.Lane, target: AVAudioFormat) {
            guard FileManager.default.fileExists(atPath: lane.url.path),
                  let f = try? AVAudioFile(forReading: lane.url), f.length > 0,
                  let c = AVAudioConverter(from: f.processingFormat, to: target) else { return nil }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            file = f
            converter = c
            gain = lane.gain
            if lane.offset >= 0 {
                silenceLeft = AVAudioFrameCount(lane.offset * Mixer.sampleRate)
            } else {
                // The lane started before the first video frame, so throw away
                // the audio that has no picture to go with it.
                silenceLeft = 0
                let skip = AVAudioFramePosition(-lane.offset * f.processingFormat.sampleRate)
                f.framePosition = min(skip, f.length)
            }
        }

        /// Exactly `frames` of target-format audio, zero-padded once the file
        /// runs out. Returns false when there is nothing left at all.
        func pull(into out: AVAudioPCMBuffer, frames: AVAudioFrameCount) -> Bool {
            out.frameLength = 0
            var produced: AVAudioFrameCount = 0

            if silenceLeft > 0 {
                let n = min(silenceLeft, frames)
                silenceLeft -= n
                produced = n   // the buffer is already zeroed below
            }
            guard produced < frames else { out.frameLength = frames; return true }
            if drained { out.frameLength = produced; return produced > 0 }

            let want = frames - produced
            guard let scratch = AVAudioPCMBuffer(pcmFormat: out.format, frameCapacity: want) else { return false }
            var err: NSError?
            let status = converter.convert(to: scratch, error: &err) { [self] need, status in
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: need) else {
                    status.pointee = .endOfStream; return nil
                }
                do { try file.read(into: buf) } catch { status.pointee = .endOfStream; return nil }
                if buf.frameLength == 0 { status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return buf
            }
            if status == .endOfStream || status == .error { drained = true }

            if scratch.frameLength > 0, let src = scratch.floatChannelData, let dst = out.floatChannelData {
                let channels = Int(out.format.channelCount)
                memcpy(dst[0].advanced(by: Int(produced) * channels), src[0],
                       Int(scratch.frameLength) * channels * MemoryLayout<Float>.size)
                produced += scratch.frameLength
            }
            out.frameLength = produced
            return produced > 0 || !drained
        }
    }

    private let target: AVAudioFormat
    private var sources: [Source] = []
    private var pts = CMTime.zero
    private let lock = NSLock()

    init(lanes: [Mux.Lane]) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Mixer.sampleRate,
                                      channels: 2, interleaved: true) else {
            throw Err("could not build the mix format")
        }
        target = fmt
        sources = lanes.compactMap { Source(lane: $0, target: fmt) }
    }

    var hasAudio: Bool { !sources.isEmpty }

    /// The next chunk of mixed audio, or nil when every lane is spent.
    func next() -> CMSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !sources.isEmpty else { return nil }
        let channels = Int(target.channelCount)
        guard let mix = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Mixer.chunk),
              let acc = mix.floatChannelData else { return nil }
        memset(acc[0], 0, Int(Mixer.chunk) * channels * MemoryLayout<Float>.size)
        mix.frameLength = 0

        var longest: AVAudioFrameCount = 0
        var alive = false
        for s in sources {
            guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Mixer.chunk),
                  let p = buf.floatChannelData else { continue }
            memset(p[0], 0, Int(Mixer.chunk) * channels * MemoryLayout<Float>.size)
            let more = s.pull(into: buf, frames: Mixer.chunk)
            if more { alive = true }
            let n = Int(buf.frameLength) * channels
            if n > 0 {
                for i in 0..<n { acc[0][i] += p[0][i] * s.gain }
                longest = max(longest, buf.frameLength)
            }
        }
        guard alive, longest > 0 else { return nil }

        // Two lanes at full tilt can sum past 1.0. Clipping there is a nasty
        // crackle, so hold everything inside the rails.
        let n = Int(longest) * channels
        for i in 0..<n { acc[0][i] = max(-1, min(1, acc[0][i])) }
        mix.frameLength = longest

        let sample = Mixer.sampleBuffer(mix, at: pts)
        pts = CMTimeAdd(pts, CMTime(value: CMTimeValue(longest), timescale: CMTimeScale(Mixer.sampleRate)))
        return sample
    }

    static func sampleBuffer(_ pcm: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        let asbd = pcm.format.streamDescription
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sizes = [Int(asbd.pointee.mBytesPerFrame)]
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(pcm.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                   sampleBufferOut: &out) == noErr,
              let out else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            out, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList) == noErr else { return nil }
        return out
    }
}
