import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// The screen, and whatever the Mac is playing, from one ScreenCaptureKit
/// stream. Video and system audio share that stream's clock, which is the
/// whole reason to take both from here rather than tapping audio separately.
///
/// SCK is gated behind Screen Recording, and that permission never prompts for
/// a self-signed app: it appears in System Settings with the toggle off and a
/// human has to flip it. Errors before that lie, notably -3801 "the user
/// declined TCCs", which really means the code requirement stopped matching.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Target {
        let display: SCDisplay
        let excluding: [SCRunningApplication]
        /// Point size of the display, needed to map a window position on screen
        /// to a pixel position in the capture.
        var pointSize: CGSize { CGSize(width: display.frame.width, height: display.frame.height) }
    }

    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "reel.screen.video")
    private let audioQueue = DispatchQueue(label: "reel.screen.audio")

    private let onVideo: @Sendable (CVPixelBuffer, CMTime) -> Void
    private let onAudio: @Sendable (AVAudioPCMBuffer, Double) -> Void
    private let recorder: WavWriter?

    let size: CGSize
    let target: Target
    let fps: Int
    private(set) var droppedIncomplete = 0
    private(set) var frames = 0

    init(target: Target, size: CGSize, fps: Int, recorder: WavWriter?,
         onVideo: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void,
         onAudio: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) {
        self.target = target
        self.size = size
        self.fps = fps
        self.recorder = recorder
        self.onVideo = onVideo
        self.onAudio = onAudio
    }

    /// Which displays are on offer, and who we are, so we can leave ourselves
    /// out of the shot.
    static func survey() async throws -> (displays: [SCDisplay], us: [SCRunningApplication]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return (content.displays, mine)
    }

    /// Capture size for a display: keep the aspect, cap the long edge, and land
    /// on even numbers because H.264 will not encode odd dimensions.
    static func captureSize(for display: SCDisplay, longEdge: Int) -> CGSize {
        let px = pixelSize(of: display)
        return captureSize(width: px.width, height: px.height, longEdge: longEdge)
    }

    /// SCDisplay reports POINTS, so a retina screen says 1512x982 when it has
    /// 3024x1964 real pixels. Capturing at the point size and calling it native
    /// throws away half the resolution, and screen recordings are mostly text,
    /// which is exactly where that shows.
    static func pixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(display.displayID),
           mode.pixelWidth > 0, mode.pixelHeight > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (display.width, display.height)
    }

    static func captureSize(width: Int, height: Int, longEdge: Int) -> CGSize {
        let w = Double(width), h = Double(height)
        let scale = min(1.0, Double(longEdge) / max(w, h))
        func even(_ x: Double) -> Double { max(2, (x * scale / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }

    func start() async throws {
        let filter = SCContentFilter(display: target.display,
                                     excludingApplications: target.excluding,
                                     exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Deep enough that a slow encode frame does not cost us a capture frame,
        // shallow enough that we are not filming several frames into the past.
        cfg.queueDepth = 6
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // Our own sounds are not part of the demo.
        cfg.excludesCurrentProcessAudio = true

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // SCK keeps handing over frames when nothing on screen has changed,
            // marked .idle with no new pixels. Encoding those would triple the
            // file for no picture.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: raw) else { return }
            guard status == .complete else {
                if status != .idle { droppedIncomplete += 1 }
                return
            }
            guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            frames += 1
            onVideo(px, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        case .audio:
            guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
                  let buf = pcmBuffer(from: sampleBuffer) else { return }
            recorder?.write(buf)
            onAudio(buf, Date().timeIntervalSince1970)

        default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("screen stream stopped: \(error)\n".data(using: .utf8)!)
    }
}
