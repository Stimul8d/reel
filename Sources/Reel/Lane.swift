import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia

/// One transcription lane: audio in one end, text out the other. Two run side
/// by side, the mic ("me") and the Mac's own output ("them"), which is how you
/// get speaker separation without a diarisation model.
///
/// Lifted from scribe, with one addition: it keeps the per-run time ranges as
/// well as the segment ones, because captions need to change every couple of
/// seconds and a finalised segment can run for ten.
actor Lane {
    let name: String
    let tag: String

    private let transcriber: SpeechTranscriber
    private var analyzer: SpeechAnalyzer!
    private let analyzerFormat: AVAudioFormat
    private var stream: AsyncStream<AnalyzerInput>!
    private var feed: AsyncStream<AnalyzerInput>.Continuation!

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var framesPushed: AVAudioFramePosition = 0
    private var lastAnchorMedia: Double = 0
    private var lastAnchorWall: Double = 0

    private(set) var finalLatencies: [Double] = []
    private(set) var confidences: [Double] = []
    private(set) var lines: [Cue] = []
    private(set) var words: [Cue] = []
    private(set) var audioSeconds: Double = 0
    private(set) var droppedLowConfidence = 0

    private let sink: any TranscriptSink
    private let minConfidence: Double

    init(name: String, tag: String, locale: Locale, sink: any TranscriptSink,
         minConfidence: Double = 0.5) async throws {
        self.name = name
        self.tag = tag
        self.sink = sink
        self.minConfidence = minConfidence

        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Err("no compatible audio format for the transcriber")
        }
        analyzerFormat = fmt
    }

    /// Pull the model down if it is not on the machine yet. Apple ships it as a
    /// system asset, so there is nothing in the bundle and this is a one-off.
    static func ensureModel(locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [probe])
        if status != .installed {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                FileHandle.standardError.write("downloading speech model...\n".data(using: .utf8)!)
                try await req.downloadAndInstall()
            }
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    func start() async throws {
        let (s, c) = AsyncStream<AnalyzerInput>.makeStream()
        stream = s
        feed = c
        // No contextualStrings. Measured in scribe: output is byte-identical
        // with and without a vocabulary list, so it is not worth the code.
        analyzer = SpeechAnalyzer(inputSequence: s, modules: [transcriber])
        Task { [weak self] in await self?.consumeResults() }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
    }

    private func consumeResults() async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }

                if !result.isFinal {
                    await sink.partial(tag: tag, text: text)
                    continue
                }

                var scores: [Double] = []
                for run in result.text.runs { if let c = run.transcriptionConfidence { scores.append(c) } }
                let score = scores.isEmpty ? 1.0 : scores.reduce(0, +) / Double(scores.count)
                // Room noise and speaker bleed come back as confident-sounding
                // nonsense at about a third the score of real speech.
                if score < minConfidence { droppedLowConfidence += 1; continue }

                let start = result.range.start.seconds
                let end = result.range.end.seconds
                let latency = Date().timeIntervalSince1970 - wallClock(forMedia: end)
                finalLatencies.append(latency)
                confidences.append(contentsOf: scores)
                lines.append(Cue(start: start, end: end, text: text))

                // Per-run ranges are what makes captions land on the right words.
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !piece.isEmpty, let r = run.audioTimeRange else { continue }
                    words.append(Cue(start: r.start.seconds, end: r.end.seconds, text: piece))
                }

                await sink.final(tag: tag, text: text, at: start, latency: latency)
            }
        } catch {
            await sink.note("[\(tag)] result stream ended: \(error)")
        }
    }

    /// Wall clock at which the audio sitting at `media` seconds was captured.
    private func wallClock(forMedia media: Double) -> Double {
        lastAnchorWall - (lastAnchorMedia - media)
    }

    /// Feed one capture buffer. `capturedAt` is unix seconds for its END.
    func push(_ buffer: AVAudioPCMBuffer, capturedAt: Double) {
        guard let out = convert(buffer) else { return }
        let startTime = CMTime(value: framesPushed, timescale: CMTimeScale(analyzerFormat.sampleRate))
        framesPushed += AVAudioFramePosition(out.frameLength)
        let endMedia = Double(framesPushed) / analyzerFormat.sampleRate
        lastAnchorMedia = endMedia
        lastAnchorWall = capturedAt
        audioSeconds = endMedia
        feed?.yield(AnalyzerInput(buffer: out, bufferStartTime: startTime))
    }

    /// The analyser wants 16 kHz mono Int16 whatever the capture hands over.
    /// One converter per lane, reused, given one buffer per convert call and
    /// then told .noDataNow.
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == analyzerFormat { return input }
        if converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: analyzerFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converterInputFormat = input.format
        }
        guard let conv = converter else { return nil }
        let ratio = analyzerFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var err: NSError?
        var handed = false
        conv.convert(to: out, error: &err) { _, status in
            if handed { status.pointee = .noDataNow; return nil }
            handed = true
            status.pointee = .haveData
            return input
        }
        if err != nil { return nil }
        return out.frameLength > 0 ? out : nil
    }

    func finish() async {
        feed?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    func result() -> LaneResult {
        LaneResult(name: name, tag: tag,
                   audioSeconds: audioSeconds,
                   lines: lines.sorted { $0.start < $1.start },
                   words: words.sorted { $0.start < $1.start },
                   meanConfidence: confidences.isEmpty ? nil : confidences.reduce(0,+) / Double(confidences.count),
                   latencies: finalLatencies,
                   dropped: droppedLowConfidence)
    }
}

struct Cue: Sendable, Codable {
    var start: Double
    var end: Double
    var text: String
}

struct LaneResult: Sendable {
    let name: String
    let tag: String
    let audioSeconds: Double
    let lines: [Cue]
    let words: [Cue]
    let meanConfidence: Double?
    let latencies: [Double]
    let dropped: Int
}
