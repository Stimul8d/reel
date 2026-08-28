import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import AppKit
import Speech

@main
struct Entry {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)   // a redirected log is block-buffered otherwise
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.contains(where: { $0.hasPrefix("--") }) else {
            ReelApp.main()   // no flags: it is the menu bar app
            return
        }
        Task { await CLI.run(args); exit(0) }
        CFRunLoopRun()
    }
}

/// Progress arrives on the encoder's queue, several times a second. This keeps
/// the printing down to one line every ten per cent.
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func step(_ p: Double) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let pct = Int(p * 100) / 10 * 10
        guard pct != last else { return nil }
        last = pct
        return pct
    }
}

enum CLI {
    static func run(_ args: [String]) async {
        func flag(_ n: String) -> Bool { args.contains(n) }
        func value(_ n: String) -> String? {
            guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        if flag("--help") { help(); return }
        if let d = value("--makeicon") { await MainActor.run { IconMaker.write(to: d) }; return }
        if flag("--probe") { await probe(); return }
        if let d = value("--burn") { await burn(dir: d); return }

        var o = Recording.Options()
        if let out = value("--out") { o.outDir = URL(fileURLWithPath: out) }
        if let d = Int(value("--display") ?? "") { o.display = d }
        if let f = Int(value("--fps") ?? "") { o.fps = f }
        if let e = Int(value("--long-edge") ?? "") { o.longEdge = e }
        if let c = value("--camera") { o.cameraName = c }
        if let c = value("--corner"), let corner = BubbleCorner(rawValue: c) { o.corner = corner }
        if let b = Double(value("--bubble") ?? "") { o.bubbleFraction = b }
        if let c = Double(value("--min-confidence") ?? "") { o.minConfidence = c }
        if flag("--no-camera") { o.camera = false }
        if flag("--no-mirror") { o.mirror = false }
        if flag("--no-mic") { o.mic = false }
        if flag("--no-system-audio") { o.systemAudio = false }
        if flag("--no-transcript") { o.transcribe = false }
        if flag("--captions") { o.burnCaptions = true }
        if flag("--hevc") { o.hevc = true }

        // The CLI opens its own camera; the menu bar app hands its preview one in.
        var camera: Camera?
        if o.camera {
            if await Camera.authorise() {
                let c = Camera()
                do { try c.start(named: o.cameraName); camera = c }
                catch { print("camera: \(error.localizedDescription), carrying on without it") }
            } else {
                print("camera permission refused, carrying on without it")
            }
        }

        let console = Console(quiet: flag("--quiet"))
        let recording = Recording(options: o, sink: console, camera: camera)
        do {
            try await recording.start()
            let seconds = Double(value("--seconds") ?? "") ?? 0
            if seconds > 0 {
                try await Task.sleep(for: .seconds(seconds))
            } else {
                print("recording. press return to stop.")
                _ = readLine()
            }
            await console.clearFooter()
            let s = try await recording.stop { print($0) }
            camera?.stop()
            report(s)
        } catch {
            camera?.stop()
            print("failed: \(error.localizedDescription)")
            if "\(error)".contains("-3801") {
                print("""
                      That error means ScreenCaptureKit could not match Reel's code requirement.
                      Check System Settings > Privacy & Security > Screen & System Audio Recording,
                      and that the app was signed with a real identity rather than ad-hoc.
                      """)
            }
        }
    }

    private static func report(_ s: Recording.Summary) {
        print("")
        print("  \(s.film.path)")
        if let c = s.captioned { print("  \(c.path)") }
        print(String(format: "  %.1fs  %dx%d  %d frames (%d dropped)  %@",
                     s.duration, Int(s.size.width), Int(s.size.height), s.frames, s.droppedFrames,
                     ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)))
        for l in s.lanes {
            let conf = l.meanConfidence.map { String(format: "%.2f", $0) } ?? "-"
            let p50 = percentile(l.latencies, 50).map { String(format: "%.1fs", $0) } ?? "-"
            print(String(format: "  %-6s %3d lines  confidence %@  final latency p50 %@  %d dropped as noise",
                         (l.tag as NSString).utf8String!, l.lines.count, conf, p50, l.dropped))
        }
    }

    /// What the machine will and will not let us do, before wasting a recording
    /// finding out. Every one of these has bitten this codebase at least once.
    private static func probe() async {
        print("bundle      \(Bundle.main.bundleIdentifier ?? "none")  at \(Bundle.main.bundlePath)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-d", "-r-", "--", Bundle.main.bundlePath]
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe
        try? task.run(); task.waitUntilExit()
        let signing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("signature   \(signing.split(separator: "\n").filter { $0.contains("designated") }.first ?? "unknown")")

        do {
            let (displays, us) = try await ScreenCapture.survey()
            print("screen      OK, \(displays.count) display(s), excluding \(us.count) of our own windows")
            for (i, d) in displays.enumerated() {
                let px = ScreenCapture.pixelSize(of: d)
                let size = ScreenCapture.captureSize(for: d, longEdge: 1920)
                print("            [\(i)] \(px.width)x\(px.height) -> records at \(Int(size.width))x\(Int(size.height))")
            }
        } catch {
            print("screen      DENIED: \(error.localizedDescription)")
            print("            System Settings > Privacy & Security > Screen & System Audio Recording.")
            print("            It never prompts for a self-signed app; the toggle starts off.")
        }

        let cams = Camera.devices()
        print("camera      \(AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? "granted" : "not yet granted"), \(cams.count) device(s)")
        for c in cams { print("            \(c.localizedName)") }

        let micState = AVCaptureDevice.authorizationStatus(for: .audio)
        print("microphone  \(micState == .authorized ? "granted" : "\(micState)")")

        let probe = SpeechTranscriber(locale: Locale(identifier: "en_GB"), preset: .progressiveTranscription)
        print("speech      model \(await AssetInventory.status(forModules: [probe]))")
    }

    /// Re-burn captions from a recording directory, after fixing a name the
    /// model got wrong in transcript.json.
    private static func burn(dir: String) async {
        let d = URL(fileURLWithPath: dir)
        guard let t = Transcript.load(from: d) else { print("no transcript.json in \(dir)"); return }
        let film = d.appendingPathComponent("recording.mp4")
        guard FileManager.default.fileExists(atPath: film.path) else { print("no recording.mp4 in \(dir)"); return }
        let out = d.appendingPathComponent("recording-captioned.mp4")
        do {
            let ticks = Ticker()
            try await Mux.burn(video: film, transcript: t, into: out) { p in
                if let pct = ticks.step(p) { print("  \(pct)%") }
            }
            print(out.path)
        } catch {
            print("failed: \(error.localizedDescription)")
        }
    }

    private static func help() {
        print("""
        reel - screen, camera and voice into one file, all on this Mac

          reel                          menu bar app (no flags)

        recording
          --seconds N                   record for N seconds instead of until return
          --out DIR                     where the files go (default ~/Movies/Reel/<timestamp>)
          --display N                   which screen (see --probe)
          --long-edge PX                cap the long edge, default 1920
          --fps N                       default 30
          --hevc                        smaller file, less portable

        the bubble
          --no-camera                   screen only
          --camera NAME                 substring match, eg "iPhone"
          --corner C                    bottomLeft | bottomRight | topLeft | topRight
          --bubble F                    diameter as a fraction of height, default 0.17
          --no-mirror                   do not mirror yourself

        sound and words
          --no-mic                      do not record your voice
          --no-system-audio             do not record what the Mac is playing
          --no-transcript               skip transcription entirely
          --captions                    burn the captions into the video too
          --min-confidence F            drop transcript lines below this, default 0.5

        after the fact
          --burn DIR                    re-burn captions from a recording directory
          --probe                       what this machine will let Reel do
        """)
    }
}
