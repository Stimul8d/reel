import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// One recording, start to finished file. The CLI and the menu bar both drive
/// this, so the awkward part only exists once.
final class Recording: @unchecked Sendable {

    struct Options: Sendable {
        var display = 0
        var fps = 30
        var longEdge = 1920
        var camera = true
        var cameraName: String?
        var mirror = true
        var corner: BubbleCorner = .bottomLeft
        var bubbleFraction: CGFloat = 0.17
        var mic = true
        var systemAudio = true
        var transcribe = true
        var burnCaptions = false
        var hevc = false
        var locale = Locale(identifier: "en_GB")
        var minConfidence = 0.5
        var outDir: URL = Recording.newOutDir()
    }

    struct Summary: Sendable {
        var dir: URL
        var film: URL
        var captioned: URL?
        var duration: Double
        var frames: Int
        var droppedFrames: Int
        var size: CGSize
        var lanes: [LaneResult]
        var bytes: Int64
    }

    /// The three clocks that have to be reconciled: the video stream, the mic,
    /// and the Mac's own output. Each notes the wall clock of its first sample
    /// so everything can be shifted onto the video's timeline afterwards.
    private final class Clocks: @unchecked Sendable {
        private let lock = NSLock()
        private var video: Double?
        private var mic: Double?
        private var system: Double?
        func markVideo(_ t: Double) { lock.lock(); if video == nil { video = t }; lock.unlock() }
        func markMic(_ t: Double) { lock.lock(); if mic == nil { mic = t }; lock.unlock() }
        func markSystem(_ t: Double) { lock.lock(); if system == nil { system = t }; lock.unlock() }
        /// Seconds to shift a lane by so it lines up with the first video frame.
        func offset(_ which: String) -> Double {
            lock.lock(); defer { lock.unlock() }
            guard let v = video else { return 0 }
            let lane = which == "me" ? mic : system
            guard let lane else { return 0 }
            return lane - v
        }
    }

    let options: Options
    private let sink: any TranscriptSink
    private let clocks = Clocks()

    private var screen: ScreenCapture?
    private var camera: Camera?
    private var mic: MicAudio?
    private var writer: VideoWriter?
    private var compositor: Compositor?
    private var lanes: [String: Lane] = [:]
    private var wavs: [WavWriter] = []
    private(set) var startedAt: Date?
    private(set) var canvas: CGSize = .zero

    /// Set by the UI as the preview bubble is dragged, in canvas pixels, so the
    /// burned-in bubble ends up where it was on screen. Nil keeps the corner.
    private let positionLock = NSLock()
    private var livePosition: CGPoint?

    /// The newest screen frame, waiting for the encoder tick to pick it up.
    private let frameLock = NSLock()
    private var latestScreen: CVPixelBuffer?
    private var screenDirty = false
    private var encoder: DispatchSourceTimer?
    private var lastEncode: Double = 0
    private(set) var encodedFrames = 0

    /// The camera is handed in already running rather than opened here. The
    /// menu bar app keeps one going for the preview bubble, and opening the
    /// same device twice to film what is already on screen is asking for
    /// trouble.
    init(options: Options, sink: any TranscriptSink, camera: Camera? = nil) {
        self.options = options
        self.sink = sink
        self.camera = camera
    }

    var outDir: URL { options.outDir }
    var elapsed: Double { startedAt.map { -$0.timeIntervalSinceNow } ?? 0 }
    var cameraDevice: Camera? { camera }

    func setBubblePosition(_ p: CGPoint?) {
        positionLock.lock(); livePosition = p; positionLock.unlock()
    }

    // MARK: - start

    func start() async throws {
        try FileManager.default.createDirectory(at: options.outDir, withIntermediateDirectories: true)

        let (displays, us) = try await ScreenCapture.survey()
        guard !displays.isEmpty else { throw Err("no display to record") }
        let display = displays[min(max(0, options.display), displays.count - 1)]
        let size = ScreenCapture.captureSize(for: display, longEdge: options.longEdge)
        canvas = size

        let comp = Compositor(canvas: size)
        comp.corner = options.corner
        comp.mirrored = options.mirror
        comp.bubbleFraction = options.bubbleFraction
        compositor = comp

        let w = try VideoWriter(url: options.outDir.appendingPathComponent("video.mp4"),
                                size: size, fps: options.fps, hevc: options.hevc)
        writer = w

        if let c = camera, c.isRunning {
            await sink.note("camera: \(c.deviceName)")
        } else if options.camera {
            await sink.note("no camera running, recording the screen only")
            camera = nil
        }

        if options.transcribe { try await Lane.ensureModel(locale: options.locale) }

        if options.mic {
            var lane: Lane?
            if options.transcribe {
                let l = try await Lane(name: "microphone", tag: "me", locale: options.locale,
                                       sink: sink, minConfidence: options.minConfidence)
                try await l.start()
                lanes["me"] = l
                lane = l
            }
            let wav = WavWriter(url: options.outDir.appendingPathComponent("me.wav"))
            wavs.append(wav)
            let micLane = lane
            let m = MicAudio(recorder: wav) { [clocks] buf, at in
                clocks.markMic(at)
                if let micLane { Task { await micLane.push(buf, capturedAt: at) } }
            }
            try m.start()
            mic = m
            await sink.note("mic: \(Int(m.inputFormat.sampleRate)) Hz")
        }

        var systemWav: WavWriter?
        var systemLane: Lane?
        if options.systemAudio {
            let wav = WavWriter(url: options.outDir.appendingPathComponent("them.wav"))
            wavs.append(wav)
            systemWav = wav
            if options.transcribe {
                let l = try await Lane(name: "system", tag: "them", locale: options.locale,
                                       sink: sink, minConfidence: options.minConfidence)
                try await l.start()
                lanes["them"] = l
                systemLane = l
            }
        }

        let sysLane = systemLane
        let target = ScreenCapture.Target(display: display, excluding: us)
        let capture = ScreenCapture(
            target: target, size: size, fps: options.fps, recorder: systemWav,
            onVideo: { [weak self] px, _ in
                self?.hold(screen: px)
            },
            onAudio: { [clocks] buf, at in
                clocks.markSystem(at)
                if let sysLane { Task { await sysLane.push(buf, capturedAt: at) } }
            })
        try await capture.start()
        screen = capture
        startEncoder()
        startedAt = Date()

        await sink.note("recording \(Int(size.width))x\(Int(size.height)) @ \(options.fps)fps -> \(options.outDir.path)")
    }

    /// ScreenCaptureKit hands over a frame only when the picture changes, so
    /// on a still screen it goes quiet for as long as you like. Encoding
    /// straight off that callback froze the camera bubble every time nothing
    /// moved, which is precisely when you are talking to it. So the callback
    /// only parks the newest frame and a timer does the encoding, at a steady
    /// rate, off whatever the newest screen and camera frames happen to be.
    private func hold(screen px: CVPixelBuffer) {
        frameLock.lock()
        latestScreen = px
        screenDirty = true
        frameLock.unlock()
    }

    private func startEncoder() {
        let queue = DispatchQueue(label: "reel.encode", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(max(1, options.fps))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        encoder = timer
    }

    private func tick() {
        guard let comp = compositor, let writer else { return }
        frameLock.lock()
        let px = latestScreen
        let dirty = screenDirty
        screenDirty = false
        frameLock.unlock()
        guard let px else { return }

        // A still screen with no camera on it needs no new frames, beyond one a
        // second so nothing has to seek across a ten minute gap.
        let now = CFAbsoluteTimeGetCurrent()
        let live = camera?.isRunning ?? false
        guard dirty || live || now - lastEncode > 1.0 else { return }
        lastEncode = now

        guard let out = writer.borrowBuffer() else { return }
        positionLock.lock()
        let p = livePosition
        positionLock.unlock()
        comp.explicitOrigin = p
        comp.render(screen: px, camera: camera?.currentFrame(), caption: nil, into: out)

        // Host time, the same clock ScreenCaptureKit stamps its own buffers
        // with, so the wall-clock offsets the audio lanes are shifted by mean
        // the same thing on both sides.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        clocks.markVideo(Date().timeIntervalSince1970)
        writer.append(out, at: pts)
        encodedFrames += 1
    }

    // MARK: - stop

    func stop(progress: (@Sendable (String) -> Void)? = nil) async throws -> Summary {
        progress?("closing the capture")
        encoder?.cancel()
        encoder = nil
        await screen?.stop()
        mic?.stop()
        frameLock.lock(); latestScreen = nil; frameLock.unlock()

        for l in lanes.values { await l.finish() }
        // The analyser emits its last finalised results a beat after the audio
        // stops. Cutting here loses the end of the last sentence.
        if !lanes.isEmpty { try? await Task.sleep(for: .milliseconds(1200)) }

        wavs.forEach { $0.close() }
        progress?("finishing the picture")
        await writer?.finish()

        let frames = encodedFrames
        let dropped = (writer?.droppedNotReady ?? 0) + (screen?.droppedIncomplete ?? 0)
        let duration = writer?.duration ?? 0

        var results: [LaneResult] = []
        var forTranscript: [(LaneResult, Double)] = []
        for tag in ["me", "them"] {
            guard let l = lanes[tag] else { continue }
            let r = await l.result()
            results.append(r)
            forTranscript.append((r, -clocks.offset(tag)))
        }

        // Captions come off the mic. The other lane is whatever the Mac was
        // playing, and captioning a demo's own soundtrack is noise.
        let transcript = Transcript.build(lanes: forTranscript, captionTags: ["me"])
        if options.transcribe { transcript.write(to: options.outDir) }

        progress?("mixing the sound in")
        let film = options.outDir.appendingPathComponent("recording.mp4")
        try await Mux.combine(
            video: options.outDir.appendingPathComponent("video.mp4"),
            lanes: [
                Mux.Lane(url: options.outDir.appendingPathComponent("me.wav"),
                         offset: clocks.offset("me"), gain: 1.0),
                // The Mac's own output sits under the voice rather than beside
                // it: you are talking over the demo, not competing with it.
                Mux.Lane(url: options.outDir.appendingPathComponent("them.wav"),
                         offset: clocks.offset("them"), gain: 0.7),
            ],
            into: film)

        var captioned: URL?
        if options.burnCaptions, !transcript.captions.isEmpty {
            progress?("burning the captions in")
            let out = options.outDir.appendingPathComponent("recording-captioned.mp4")
            try await Mux.burn(video: film, transcript: transcript, into: out) { p in
                progress?("burning the captions in (\(Int(p * 100))%)")
            }
            captioned = out
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: (captioned ?? film).path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        startedAt = nil
        screen = nil; camera = nil; mic = nil; writer = nil; compositor = nil
        lanes.removeAll(); wavs.removeAll()

        return Summary(dir: options.outDir, film: film, captioned: captioned,
                       duration: duration, frames: frames, droppedFrames: dropped,
                       size: canvas, lanes: results, bytes: bytes)
    }

    /// One directory per recording, named so they sort.
    static func newOutDir() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return URL(fileURLWithPath: NSHomeDirectory() + "/Movies/Reel/" + f.string(from: Date()))
    }
}
