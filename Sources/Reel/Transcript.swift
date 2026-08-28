import Foundation

/// Where transcript lines go while a recording is running: the terminal, the
/// menu bar panel, and the file on disk all take the same feed.
protocol TranscriptSink: Sendable {
    func final(tag: String, text: String, at start: Double, latency: Double?) async
    func partial(tag: String, text: String) async
    func note(_ s: String) async
}

struct FanOut: TranscriptSink {
    let sinks: [any TranscriptSink]
    func final(tag: String, text: String, at start: Double, latency: Double?) async {
        for s in sinks { await s.final(tag: tag, text: text, at: start, latency: latency) }
    }
    func partial(tag: String, text: String) async { for s in sinks { await s.partial(tag: tag, text: text) } }
    func note(_ text: String) async { for s in sinks { await s.note(text) } }
}

struct Silent: TranscriptSink {
    func final(tag: String, text: String, at start: Double, latency: Double?) async {}
    func partial(tag: String, text: String) async {}
    func note(_ s: String) async {}
}

/// Two-lane live display for the terminal. Finalised text scrolls; the in-flight
/// guess for each lane sits in a footer that gets rewritten in place.
actor Console: TranscriptSink {
    private var partials: [String: String] = [:]
    private let order = ["me", "them"]
    private let ansi: Bool
    private var footerDrawn = false
    private let quiet: Bool

    init(quiet: Bool = false) {
        self.quiet = quiet
        ansi = !quiet && isatty(1) == 1
    }

    private var width: Int {
        var w = winsize()
        if ioctl(1, UInt(TIOCGWINSZ), &w) == 0, w.ws_col > 20 { return Int(w.ws_col) }
        return 100
    }

    private func out(_ s: String) {
        guard !quiet else { return }
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }

    private func clock(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
    private func colour(_ tag: String) -> String {
        guard ansi else { return "" }
        return tag == "me" ? "\u{1B}[36m" : "\u{1B}[33m"
    }
    private var reset: String { ansi ? "\u{1B}[0m" : "" }
    private var dim: String { ansi ? "\u{1B}[2m" : "" }

    func final(tag: String, text: String, at start: Double, latency: Double?) {
        partials[tag] = nil
        emit("\(dim)\(clock(start))\(reset) \(colour(tag))\(pad(tag))\(reset) \(text)")
    }
    func partial(tag: String, text: String) { partials[tag] = text; redrawFooter() }
    func note(_ s: String) { emit("\(dim)\(s)\(reset)") }

    private func pad(_ tag: String) -> String {
        String(tag.prefix(6)).padding(toLength: 6, withPad: " ", startingAt: 0)
    }

    private func emit(_ line: String) {
        if ansi && footerDrawn { out("\u{1B}[2A\r\u{1B}[0J"); footerDrawn = false }
        out(line + "\n")
        redrawFooter()
    }

    private func redrawFooter() {
        guard ansi else { return }
        if footerDrawn { out("\u{1B}[2A\r\u{1B}[0J") }
        let w = width
        for tag in order {
            let body = partials[tag] ?? ""
            var s = "\(dim)  \(colour(tag))\(pad(tag))\(reset)\(dim) \(body)\(reset)"
            if body.count + 10 > w {
                s = "\(dim)  \(colour(tag))\(pad(tag))\(reset)\(dim) ...\(String(body.suffix(max(10, w - 14))))\(reset)"
            }
            out(s + "\n")
        }
        footerDrawn = true
    }

    func clearFooter() {
        if ansi && footerDrawn { out("\u{1B}[2A\r\u{1B}[0J"); footerDrawn = false }
    }
}

/// The finished transcript, on the video's clock rather than the audio's.
struct Transcript: Codable, Sendable {
    struct Line: Codable, Sendable {
        var tag: String
        var start: Double
        var end: Double
        var text: String
    }
    var lines: [Line] = []
    var captions: [Cue] = []

    /// Build from the lanes, shifting each onto the video timeline. The mic and
    /// the ScreenCaptureKit stream start a fraction of a second apart, and left
    /// uncorrected that is exactly the kind of caption drift you notice but
    /// cannot explain.
    static func build(lanes: [(result: LaneResult, offset: Double)], captionTags: Set<String>) -> Transcript {
        var t = Transcript()
        for (r, offset) in lanes {
            for c in r.lines {
                t.lines.append(Line(tag: r.tag, start: max(0, c.start + offset),
                                    end: max(0, c.end + offset), text: c.text))
            }
        }
        t.lines.sort { $0.start < $1.start }

        var words: [Cue] = []
        for (r, offset) in lanes where captionTags.contains(r.tag) {
            // Fall back to whole lines if the model gave no per-word ranges.
            let source = r.words.isEmpty ? r.lines : r.words
            words.append(contentsOf: source.map {
                Cue(start: max(0, $0.start + offset), end: max(0, $0.end + offset), text: $0.text)
            })
        }
        words.sort { $0.start < $1.start }
        t.captions = chunk(words)
        return t
    }

    /// Group words into caption-sized bites. Break on a long pause, on a
    /// sentence ending, or when the line gets too wide to read at a glance.
    static func chunk(_ words: [Cue], maxChars: Int = 46, maxSeconds: Double = 3.2,
                      gap: Double = 0.7) -> [Cue] {
        var out: [Cue] = []
        var current: Cue?
        for w in words {
            guard var c = current else { current = w; continue }
            let joined = c.text + " " + w.text
            let tooLong = joined.count > maxChars
            let tooSlow = w.end - c.start > maxSeconds
            let paused = w.start - c.end > gap
            let ended = c.text.hasSuffix(".") || c.text.hasSuffix("?") || c.text.hasSuffix("!")
            if tooLong || tooSlow || paused || ended {
                out.append(c)
                current = w
            } else {
                c.text = joined
                c.end = w.end
                current = c
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// The caption on screen at `t`, if any. Captions hang around a beat after
    /// the words end so a short one does not flash.
    func caption(at t: Double, hold: Double = 0.4) -> String? {
        for c in captions where t >= c.start && t <= c.end + hold { return c.text }
        return nil
    }

    func plainText() -> String {
        lines.map { l in
            String(format: "[%02d:%02d] %@: %@", Int(l.start) / 60, Int(l.start) % 60, l.tag, l.text)
        }.joined(separator: "\n") + "\n"
    }

    /// SRT as well as burned-in captions, because a .srt sits next to the file
    /// and can be turned off, which burning them cannot.
    func srt() -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t - floor(t)) * 1000)
            let s = Int(t)
            return String(format: "%02d:%02d:%02d,%03d", s / 3600, (s % 3600) / 60, s % 60, ms)
        }
        return captions.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start)) --> \(stamp(max(c.end, c.start + 0.6)))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    func write(to dir: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: dir.appendingPathComponent("transcript.json")) }
        try? plainText().write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try? srt().write(to: dir.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
    }

    static func load(from dir: URL) -> Transcript? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: d)
    }
}
