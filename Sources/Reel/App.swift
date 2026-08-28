import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

/// Everything the menu bar needs to know. One of these for the life of the app.
@MainActor
final class Studio: ObservableObject {
    enum Stage: Equatable { case idle, recording, working(String) }

    @Published var stage: Stage = .idle
    @Published var elapsed: Double = 0
    @Published var status = ""
    @Published var last: Recording.Summary?
    @Published var displays: [DisplayChoice] = []
    @Published var cameras: [String] = []

    @Published var displayIndex = 0 { didSet { restartPreview() } }
    @Published var cameraOn = true { didSet { cameraOn ? startPreview() : stopPreview() } }
    @Published var cameraName = "" { didSet { restartPreview() } }
    @Published var corner: BubbleCorner = .bottomLeft { didSet { restartPreview() } }
    @Published var bubbleSize: Double = 0.17 { didSet { restartPreview() } }
    @Published var mirror = true { didSet { preview.setRecording(stage == .recording) ; restartPreview() } }
    @Published var micOn = true
    @Published var systemAudioOn = true
    @Published var transcribe = true
    @Published var burnCaptions = false
    @Published var longEdge = 1920
    @Published var fps = 30

    struct DisplayChoice: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let label: String
        let width: Int
        let height: Int
    }

    private var recording: Recording?
    private var camera: Camera?
    private let preview = Bubble()
    private var ticker: Timer?
    private var bubbleOrigin: CGPoint?

    init() {
        preview.onMove = { [weak self] p in
            self?.bubbleOrigin = p
            self?.recording?.setBubblePosition(p)
        }
        Task { await refresh() }
    }

    var canRecord: Bool { stage == .idle }

    func refresh() async {
        cameras = Camera.devices().map(\.localizedName)
        if cameraName.isEmpty { cameraName = cameras.first ?? "" }
        do {
            let (list, _) = try await ScreenCapture.survey()
            displays = list.enumerated().map { i, d in
                let px = ScreenCapture.pixelSize(of: d)
                return DisplayChoice(id: d.displayID,
                                     label: list.count == 1 ? "Display" : "Display \(i + 1) (\(px.width)x\(px.height))",
                                     width: px.width, height: px.height)
            }
            if displayIndex >= displays.count { displayIndex = 0 }
            status = ""
        } catch {
            // This is what a missing Screen Recording grant looks like. It never
            // prompts for a self-signed app; the toggle has to be flipped by hand.
            displays = []
            status = "Screen Recording is off for Reel. System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch."
        }
        if cameraOn { startPreview() }
    }

    // MARK: - preview bubble

    private func canvasSize() -> CGSize {
        guard displayIndex < displays.count else { return CGSize(width: 1920, height: 1080) }
        let d = displays[displayIndex]
        return ScreenCapture.captureSize(width: d.width, height: d.height, longEdge: longEdge)
    }

    func startPreview() {
        guard cameraOn, displayIndex < displays.count else { return }
        Task {
            guard await Camera.authorise() else {
                status = "Camera permission refused."
                cameraOn = false
                return
            }
            if camera == nil || !(camera?.isRunning ?? false) {
                let c = Camera()
                do { try c.start(named: cameraName.isEmpty ? nil : cameraName) }
                catch {
                    status = "No camera: \(error.localizedDescription)"
                    return
                }
                camera = c
            }
            guard let camera else { return }
            let canvas = canvasSize()
            preview.show(camera: camera, canvas: canvas,
                         diameterPixels: (canvas.height * bubbleSize / 2).rounded() * 2,
                         on: displays[displayIndex].id,
                         corner: corner, inset: (canvas.height * 0.025).rounded(),
                         mirrored: mirror)
            preview.setRecording(stage == .recording)
        }
    }

    func stopPreview() {
        preview.hide()
        camera?.stop()
        camera = nil
        bubbleOrigin = nil
    }

    private func restartPreview() {
        guard cameraOn else { return }
        startPreview()
    }

    // MARK: - record

    func start() {
        guard canRecord else { return }
        var o = Recording.Options()
        o.display = displayIndex
        o.fps = fps
        o.longEdge = longEdge
        o.camera = cameraOn
        o.cameraName = cameraName.isEmpty ? nil : cameraName
        o.mirror = mirror
        o.corner = corner
        o.bubbleFraction = bubbleSize
        o.mic = micOn
        o.systemAudio = systemAudioOn
        o.transcribe = transcribe
        o.burnCaptions = burnCaptions

        let r = Recording(options: o, sink: Silent(), camera: cameraOn ? camera : nil)
        recording = r
        if let bubbleOrigin { r.setBubblePosition(bubbleOrigin) }
        status = ""
        Task {
            do {
                try await r.start()
                stage = .recording
                preview.setRecording(true)
                elapsed = 0
                ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    MainActor.assumeIsolated { self.elapsed = r.elapsed }
                }
            } catch {
                recording = nil
                stage = .idle
                status = friendly(error)
            }
        }
    }

    func stop() {
        guard stage == .recording, let r = recording else { return }
        ticker?.invalidate(); ticker = nil
        stage = .working("finishing")
        preview.setRecording(false)
        Task {
            do {
                let summary = try await r.stop { note in
                    Task { @MainActor in self.stage = .working(note) }
                }
                last = summary
                status = ""
            } catch {
                status = friendly(error)
            }
            recording = nil
            stage = .idle
        }
    }

    /// Re-burn captions onto an existing recording, after a name has been
    /// corrected in transcript.json.
    func reburn(_ summary: Recording.Summary) {
        guard stage == .idle, let t = Transcript.load(from: summary.dir) else { return }
        stage = .working("burning the captions in")
        Task {
            do {
                let out = summary.dir.appendingPathComponent("recording-captioned.mp4")
                try await Mux.burn(video: summary.film, transcript: t, into: out) { p in
                    Task { @MainActor in self.stage = .working("burning the captions in (\(Int(p * 100))%)") }
                }
                var s = summary
                s.captioned = out
                last = s
            } catch {
                status = friendly(error)
            }
            stage = .idle
        }
    }

    private func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        // -3801 is what ScreenCaptureKit says when the code requirement stopped
        // matching, which is not the same thing as anyone declining anything.
        if text.contains("-3801") || text.contains("declined") {
            return "Screen Recording is off for Reel (or the app was re-signed). System Settings > Privacy & Security > Screen & System Audio Recording."
        }
        return text
    }
}

/// Not @main: Entry in main.swift decides between this and the CLI depending on
/// whether any flags were passed.
struct ReelApp: App {
    @StateObject private var studio = Studio()

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(studio)
        } label: {
            Image(systemName: studio.stage == .recording ? "record.circle.fill" : "record.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !studio.status.isEmpty {
                Text(studio.status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            settings
            if let last = studio.last {
                Divider()
                finished(last)
            }
            Divider()
            HStack {
                Button("Recordings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Movies/Reel"))
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .task { await studio.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            switch studio.stage {
            case .idle:
                Button(action: studio.start) {
                    Label("Record", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("r")
                .disabled(studio.displays.isEmpty)
            case .recording:
                Button(action: studio.stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text(clock(studio.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.red)
            case .working(let what):
                ProgressView().controlSize(.small)
                Text(what).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var settings: some View {
        Toggle("Camera", isOn: $studio.cameraOn)
        if studio.cameraOn {
            if studio.cameras.count > 1 {
                Picker("Device", selection: $studio.cameraName) {
                    ForEach(studio.cameras, id: \.self) { Text($0).tag($0) }
                }
            }
            Picker("Corner", selection: $studio.corner) {
                ForEach(BubbleCorner.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Size")
                Slider(value: $studio.bubbleSize, in: 0.10...0.30)
                Text("\(Int(studio.bubbleSize * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Toggle("Mirror me", isOn: $studio.mirror)
            Text("Drag the bubble anywhere. It is not in the recording twice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Microphone", isOn: $studio.micOn)
        Toggle("This Mac's sound", isOn: $studio.systemAudioOn)
        Toggle("Transcribe", isOn: $studio.transcribe)
        if studio.transcribe {
            Toggle("Burn captions into the video", isOn: $studio.burnCaptions)
        }
        if studio.displays.count > 1 {
            Picker("Screen", selection: $studio.displayIndex) {
                ForEach(Array(studio.displays.enumerated()), id: \.offset) { i, d in
                    Text(d.label).tag(i)
                }
            }
        }
        Picker("Quality", selection: $studio.longEdge) {
            Text("720p").tag(1280)
            Text("1080p").tag(1920)
            Text("1440p").tag(2560)
            Text("Native").tag(8192)
        }
    }

    private func finished(_ s: Recording.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last recording")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(clock(s.duration))  ·  \(Int(s.size.width))x\(Int(s.size.height))  ·  \(bytes(s.bytes))")
                .font(.callout.monospacedDigit())
            HStack(spacing: 14) {
                Button("Open") { NSWorkspace.shared.open(s.captioned ?? s.film) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([s.captioned ?? s.film])
                }
                if s.captioned == nil, studio.stage == .idle {
                    Button("Burn captions") { studio.reburn(s) }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func clock(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
