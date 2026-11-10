// The transcript: words with the time they were spoken, from the Mac's own on-device
// speech recognition (the Speech framework's SpeechAnalyzer, macOS 26+), or from a
// words.json written earlier and corrected by hand.

import AVFoundation
import Foundation
import Speech

public struct Word: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(_ text: String, _ start: Double, _ end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct Transcript: Codable, Equatable, Sendable {
    public var source: String
    public var duration: Double
    public var locale: String
    public var words: [Word]

    public init(source: String, duration: Double, locale: String, words: [Word]) {
        self.source = source; self.duration = duration; self.locale = locale; self.words = words
    }

    public static func load(_ url: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url)
    }
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case needsMacOS26
    case noAudio(String)
    public var description: String {
        switch self {
        case .needsMacOS26: return "transcription needs macOS 26 or later (SpeechAnalyzer)"
        case .noAudio(let f): return "\(f) has no audio track to transcribe"
        }
    }
}

public enum Transcriber {
    /// Word timings for an audio or video file. A recognizer run that holds several words
    /// shares its time span between them in proportion to their lengths.
    public static func transcribe(_ url: URL, locale localeID: String = "en-US",
                                  status: ((String) -> Void)? = nil) async throws -> Transcript {
        guard #available(macOS 26, *) else { throw TranscriptionError.needsMacOS26 }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let words = try await words(url: url, localeID: localeID, status: status)
        return Transcript(source: url.path, duration: duration, locale: localeID, words: words)
    }

    @available(macOS 26, *)
    static func words(url: URL, localeID: String, status: ((String) -> Void)?) async throws -> [Word] {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: localeID),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status?("downloading speech model for \(localeID)")
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    if parts.isEmpty { continue }
                    let start = range.start.seconds, end = range.end.seconds
                    let total = Double(parts.reduce(0) { $0 + $1.count })
                    var t = start
                    for p in parts {
                        let share = total > 0 ? (end - start) * Double(p.count) / total : 0
                        words.append(Word(p, t, t + share))
                        t += share
                    }
                }
            }
            return words
        }
        // The analyzer refuses some files as they are (a ProRes .mov's 24-bit stereo
        // fails with a bare nilError), so the audio is always converted to the format
        // the analyzer asks for, into a temporary file.
        let source = try await audioFile(for: url, status: status)
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let file = try convert(source, to: best)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// AVAudioFile reads .wav, .m4a, .mp3 and .caf. It also opens a QuickTime movie, but
    /// the first read from one throws a bare nilError, so anything with a video track is
    /// decoded through AVAssetReader to a temporary PCM .caf first.
    static func audioFile(for url: URL, status: ((String) -> Void)?) async throws -> AVAudioFile {
        let asset = AVURLAsset(url: url)
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        if !hasVideo, let f = try? AVAudioFile(forReading: url) { return f }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriptionError.noAudio(url.lastPathComponent) }
        status?("extracting the audio")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phraseo-\(UUID().uuidString).caf")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscriptionError.noAudio(url.lastPathComponent) }
        var file: AVAudioFile?
        while let sb = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sb),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            if file == nil {
                file = try AVAudioFile(forWriting: tmp, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            }
            let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { continue }
            buf.frameLength = n
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
            try file!.write(from: buf)
        }
        if let e = reader.error { throw e }
        file = nil  // closes it
        return try AVAudioFile(forReading: tmp)
    }

    /// `source` resampled and mixed to `format`, as a temporary .caf opened for reading.
    static func convert(_ source: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioFile {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phraseo-\(UUID().uuidString).caf")
        guard let converter = AVAudioConverter(from: source.processingFormat, to: format) else {
            throw TranscriptionError.noAudio(source.url.lastPathComponent)
        }
        var out: AVAudioFile? = try AVAudioFile(forWriting: tmp, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let chunk: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: chunk) else {
            throw TranscriptionError.noAudio(source.url.lastPathComponent)
        }
        // Each chunk is read outside the converter's input block and handed over once;
        // after the last chunk the converter is drained with endOfStream. The read asks
        // for exactly the frames left: on macOS 26 a read that runs past the end of the
        // file throws a bare nilError instead of returning the short tail.
        var ended = false
        while true {
            if !ended {
                let left = AVAudioFrameCount(max(0, source.length - source.framePosition))
                if left == 0 { ended = true; inBuf.frameLength = 0 }
                else { try source.read(into: inBuf, frameCount: min(chunk, left)) }
            }
            var handed = false
            var flushed = false
            repeat {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                var convError: NSError?
                let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                    if ended { outStatus.pointee = .endOfStream; return nil }
                    if handed { outStatus.pointee = .noDataNow; return nil }
                    handed = true
                    outStatus.pointee = .haveData
                    return inBuf
                }
                if let e = convError { throw e }
                if outBuf.frameLength > 0 { try out!.write(from: outBuf) }
                if status == .error { throw TranscriptionError.noAudio(source.url.lastPathComponent) }
                flushed = status == .endOfStream || status == .inputRanDry
            } while !flushed
            if ended { break }
        }
        out = nil  // closes the file so its header is final before it is read
        return try AVAudioFile(forReading: tmp)
    }
}
