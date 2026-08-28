import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

/// Everything that happens after you press stop.
///
/// The live pass writes picture and sound separately: `video.mp4` with no audio
/// track, plus one wav per lane. That is deliberate. The mic and the
/// ScreenCaptureKit stream run off different hardware clocks, and summing two
/// clocks in real time gives you drift that cannot be undone afterwards. Here
/// there is no clock pressure, so the two lanes get lined up once, mixed, and
/// muxed onto the picture.
enum Mux {

    struct Lane {
        var url: URL
        /// Seconds after the first video frame that this lane's audio starts.
        var offset: Double
        var gain: Float
    }

    // MARK: - audio + video into one file

    static func combine(video: URL, lanes: [Lane], into out: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Err("\(video.lastPathComponent) has no video track")
        }

        let reader = try AVAssetReader(asset: asset)
        // Nil output settings means the compressed samples come through
        // untouched, so the picture is never re-encoded just to gain a sound.
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw Err("cannot read the video track") }
        reader.add(vOut)

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                     sourceFormatHint: try await vTrack.load(.formatDescriptions).first)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw Err("cannot write the video track") }
        writer.add(vIn)

        let mixer = try Mixer(lanes: lanes)
        var aIn: AVAssetWriterInput?
        if mixer.hasAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Mixer.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input }
        }

        guard writer.startWriting() else { throw Err("could not start the mux: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw Err("could not read \(video.lastPathComponent)") }

        let vSource = UncheckedBox(vOut)
        async let videoDone: Void = pump(vIn, label: "video") { vSource.value.copyNextSampleBuffer() }
        let audioInput = aIn
        async let audioDone: Void = {
            guard let audioInput else { return }
            await pump(audioInput, label: "audio") { mixer.next() }
        }()
        _ = await (videoDone, audioDone)

        if reader.status == .failed { throw Err("reading failed: \(reader.error?.localizedDescription ?? "?")") }
        await writer.finishWriting()
        if writer.status == .failed { throw Err("mux failed: \(writer.error?.localizedDescription ?? "?")") }
    }

    /// Feed one writer input until its source runs dry, respecting back
    /// pressure. requestMediaDataWhenReady is the only supported way to do this
    /// without spinning a core on isReadyForMoreMediaData.
    private static func pump(_ input: AVAssetWriterInput, label: String,
                             next: @escaping @Sendable () -> CMSampleBuffer?) async {
        let queue = DispatchQueue(label: "reel.mux.\(label)")
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let done = Resumer(k)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = next() else {
                        input.markAsFinished()
                        done.fire()
                        return
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        done.fire()
                        return
                    }
                }
            }
        }
    }

    /// requestMediaDataWhenReady can fire again after we have finished, and
    /// resuming a continuation twice is a crash, not a warning.
    private final class Resumer: @unchecked Sendable {
        private var k: CheckedContinuation<Void, Never>?
        private let lock = NSLock()
        init(_ k: CheckedContinuation<Void, Never>) { self.k = k }
        func fire() {
            lock.lock(); let c = k; k = nil; lock.unlock()
            c?.resume()
        }
    }

    // MARK: - burning captions in

    /// A second pass, and only ever a second pass. The clean recording stays on
    /// disk untouched, so a name the model got wrong can be fixed in
    /// transcript.json and the captions re-burned without recording anything
    /// again.
    static func burn(video: URL, transcript: Transcript, into out: URL,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: video)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Err("\(video.lastPathComponent) has no video track")
        }
        let size = try await vTrack.load(.naturalSize)
        let fps = max(1, Int(try await vTrack.load(.nominalFrameRate).rounded()))
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw Err("cannot decode the video track") }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        if let aTrack {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            o.alwaysCopiesSampleData = false
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let bitrate = Int(min(16_000_000, max(2_000_000, Double(size.width * size.height) * Double(fps) / 10)))
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            ] as [String: Any],
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])
        guard writer.canAdd(vIn) else { throw Err("cannot write the captioned video track") }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if let aTrack, aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                       sourceFormatHint: try await aTrack.load(.formatDescriptions).first)
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) { writer.add(i); aIn = i }
        }

        guard writer.startWriting() else { throw Err("could not start the caption pass") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw Err("could not read \(video.lastPathComponent)") }

        // The compositor only draws the caption here; the camera is already in
        // the picture from the live pass.
        let comp = Compositor(canvas: size)
        let sendableAdaptor = UncheckedBox(adaptor)

        let vSource = UncheckedBox(vOut)
        let audioInput = aIn
        let aSource = aOut.map { UncheckedBox($0) }
        async let videoDone: Void = pump(vIn, label: "burn.video") {
            guard let sample = vSource.value.copyNextSampleBuffer() else { return nil }
            guard let src = CMSampleBufferGetImageBuffer(sample) else { return sample }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let pool = sendableAdaptor.value.pixelBufferPool else { return sample }
            var dst: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
                  let dst else { return sample }
            comp.render(screen: src, camera: nil, caption: transcript.caption(at: pts.seconds), into: dst)
            if duration > 0 { progress?(min(1, pts.seconds / duration)) }
            return Self.sampleBuffer(from: dst, at: pts, template: sample)
        }
        async let audioDone: Void = {
            guard let audioInput, let aSource else { return }
            await pump(audioInput, label: "burn.audio") { aSource.value.copyNextSampleBuffer() }
        }()
        _ = await (videoDone, audioDone)

        await writer.finishWriting()
        if writer.status == .failed { throw Err("caption pass failed: \(writer.error?.localizedDescription ?? "?")") }
    }

    /// Wrap a pixel buffer back into a sample buffer carrying the original
    /// timing, so the re-encoded frames land exactly where the originals did.
    private static func sampleBuffer(from pixels: CVPixelBuffer, at pts: CMTime,
                                     template: CMSampleBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixels,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(template),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: pixels,
                                                       formatDescription: format,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}

/// CoreImage and AVFoundation objects that are safe to hand across an await
/// here because only one task ever touches them.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { self.value = v }
}
