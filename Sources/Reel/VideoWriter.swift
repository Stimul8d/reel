import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import CoreMedia
import VideoToolbox

/// Writes the composited frames straight out as H.264 while the recording is
/// happening. Video only: the audio arrives on a different clock and gets muxed
/// in afterwards by Mux.swift.
final class VideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var firstPTS: CMTime?
    private(set) var written = 0
    private(set) var droppedNotReady = 0
    private(set) var lastPTS: CMTime = .zero
    let size: CGSize
    let url: URL

    init(url: URL, size: CGSize, fps: Int, hevc: Bool) throws {
        self.url = url
        self.size = size
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Screen content is mostly flat colour and text, so it compresses far
        // better than camera video. A tenth of a bit per pixel is generous
        // here and still lands a ten minute 1080p recording under a gigabyte.
        let pixelsPerSecond = Double(size.width * size.height) * Double(fps)
        let bitrate = Int(min(16_000_000, max(2_000_000, pixelsPerSecond / 10)))

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            // B-frames buy a little size and cost latency and seek accuracy.
            AVVideoAllowFrameReorderingKey: false,
            // A keyframe every two seconds keeps scrubbing usable.
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoExpectedSourceFrameRateKey: fps,
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }

        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                // Without this the pool hands back buffers CoreImage has to copy
                // before Metal can touch them.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])

        guard writer.canAdd(input) else { throw Err("asset writer refused the video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Err("could not start writing \(url.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// A blank frame from the adaptor's pool, ready for the compositor to draw
    /// into. Nil once the writer has been finished.
    func borrowBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    /// The first frame sets time zero, so the file starts when the recording
    /// did rather than at whatever the capture clock happened to read.
    func append(_ buffer: CVPixelBuffer, at pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        if firstPTS == nil {
            firstPTS = pts
            writer.startSession(atSourceTime: .zero)
        }
        guard let first = firstPTS else { return }
        // The encoder is real-time: a frame it is not ready for is a frame we
        // drop, because holding it would push everything after it late.
        guard input.isReadyForMoreMediaData else { droppedNotReady += 1; return }
        let t = CMTimeSubtract(pts, first)
        if adaptor.append(buffer, withPresentationTime: t) {
            written += 1
            lastPTS = t
        }
    }

    var duration: Double { lastPTS.seconds }

    func finish() async {
        lock.lock()
        input.markAsFinished()
        lock.unlock()
        await writer.finishWriting()
        if writer.status == .failed {
            FileHandle.standardError.write("video writer failed: \(writer.error?.localizedDescription ?? "?")\n".data(using: .utf8)!)
        }
    }
}
