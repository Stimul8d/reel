import Foundation
@preconcurrency import AVFoundation
import CoreMedia

struct Err: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let i = min(s.count - 1, max(0, Int(((p / 100.0) * Double(s.count - 1)).rounded())))
    return s[i]
}

/// Microphone, via AVAudioEngine. This is you talking over the demo.
final class MicAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let onBuffer: @Sendable (AVAudioPCMBuffer, Double) -> Void
    private let recorder: WavWriter?

    init(recorder: WavWriter?, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) {
        self.recorder = recorder
        self.onBuffer = onBuffer
    }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start() throws {
        let node = engine.inputNode
        // Voice processing (the FaceTime echo canceller) is deliberately NOT on.
        // It ducks everything else playing on the machine, hard, which for a
        // screen recording means the app you are demoing goes quiet every time
        // you speak. Same call as in scribe, same reason.
        let fmt = node.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            throw Err("microphone unavailable (0 Hz input format) - permission, or no device")
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            let b = firstChannel(of: buf) ?? buf
            self.recorder?.write(b)
            self.onBuffer(b, Date().timeIntervalSince1970)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Multi-channel input collapses to one channel. Nothing downstream wants
/// several copies of the same signal.
func firstChannel(of buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard buf.format.channelCount > 1,
          let src = buf.floatChannelData,
          let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: buf.format.sampleRate,
                                   channels: 1, interleaved: false),
          let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
          let dst = out.floatChannelData else { return nil }
    out.frameLength = buf.frameLength
    memcpy(dst[0], src[0], Int(buf.frameLength) * MemoryLayout<Float>.size)
    return out
}

/// CMSampleBuffer -> AVAudioPCMBuffer without copying more than we have to.
func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let fd = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
          let format = AVAudioFormat(streamDescription: asbd) else { return nil }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
    guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    out.frameLength = frames
    var copied = false
    try? sample.withAudioBufferList { abl, _ in
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl.unsafePointer))
        guard dst.count == src.count else { return }
        for i in 0..<dst.count {
            guard let s = src[i].mData, let d = dst[i].mData else { return }
            let n = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
            memcpy(d, s, n)
            dst[i].mDataByteSize = UInt32(n)
        }
        copied = true
    }
    return copied ? out : nil
}

/// Audio goes to disk raw and gets muxed into the film afterwards, never mixed
/// live. The mic and the system output run on different hardware clocks, and
/// summing two clocks in real time is how you get drift you cannot correct
/// later. On disk they stay separate, so the mux can align them once, and the
/// captions can be re-cut from the same wavs without recording anything twice.
final class WavWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let url: URL
    private let lock = NSLock()
    private(set) var frames: AVAudioFramePosition = 0

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        do {
            if file == nil {
                // The file on disk is interleaved either way, but the processing
                // format has to match the buffers we are handed or every write
                // fails with ExtAudioFileWrite -50. Only the settings key needs
                // dropping, and only to keep CoreAudio quiet in the log.
                var settings = buffer.format.settings
                settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
                file = try AVAudioFile(forWriting: url,
                                       settings: settings,
                                       commonFormat: buffer.format.commonFormat,
                                       interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            FileHandle.standardError.write("wav write failed \(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
        }
    }

    func close() { lock.lock(); file = nil; lock.unlock() }
}
