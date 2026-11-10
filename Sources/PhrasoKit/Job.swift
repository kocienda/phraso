// A job: one video in, one caption track out, as a movie to drag onto the Final Cut
// timeline. The video's own size and frame rate set the timeline; the transcript comes
// from the file or from a words.json beside it.

import Foundation

public enum Phase: String, Sendable {
    case probing, transcribing, rendering, writing, done
}

public struct Job: Sendable {
    public var video: URL
    public var style: Style
    /// Where the outputs go; the video's folder by default.
    public var outputDirectory: URL
    /// Base name of the outputs; the video's stem plus ".captions" by default.
    public var name: String
    /// A corrected transcript to use instead of transcribing.
    public var words: URL?
    /// A transcript already in hand (the app's edited one); wins over `words`.
    public var transcript: Transcript?
    public var locale: String = "en-US"
    public var codec: Codec = .hevc
    /// HEVC's quality, 0...1 (`MovieWriter.quality`).
    public var quality: Double = MovieWriter.defaultQuality
    public var background: Background = .gap
    /// What fills the frame behind the cards (`Matte`); clear leaves the alpha channel.
    public var matte: Matte = .clear
    /// The movie's shorter side in pixels, scaled from the video's size; nil for the
    /// video's own size. Final Cut fits the track to the project either way.
    public var lines: Int?
    /// Also write the transcript beside the movie, to correct and run again with `words`.
    public var writesWords = true
    /// Also write SubRip subtitles (`Subtitles`), one cue per card.
    public var writesSubtitles = false
    /// Also write the FCPXML that places the movie in a project of its own (`FCPXML`).
    public var writesFCPXML = false

    public init(video: URL, style: Style, outputDirectory: URL? = nil, name: String? = nil, words: URL? = nil) {
        self.video = video
        self.style = style
        self.outputDirectory = outputDirectory ?? video.deletingLastPathComponent()
        self.name = name ?? video.deletingPathExtension().lastPathComponent + ".captions"
        self.words = words
    }

    public var movieURL: URL { outputDirectory.appendingPathComponent(name + ".mov") }
    public var fcpxmlURL: URL { outputDirectory.appendingPathComponent(name + ".fcpxml") }
    public var wordsURL: URL { outputDirectory.appendingPathComponent(name + ".words.json") }
    public var subtitlesURL: URL { outputDirectory.appendingPathComponent(name + ".srt") }

    /// The movie's size for a video of `width` × `height`: the video's own, or scaled so
    /// its shorter side is `lines`, with both sides even, as the encoders want.
    public static func size(width: Int, height: Int, lines: Int?) -> (width: Int, height: Int) {
        guard let l = lines, l > 0, l != min(width, height) else { return (width, height) }
        let s = Double(l) / Double(min(width, height))
        func even(_ v: Int) -> Int { max(2, Int((Double(v) * s / 2).rounded()) * 2) }
        return (even(width), even(height))
    }

    public struct Outputs: Sendable {
        public var movie: URL
        /// Nil unless the job was asked for one.
        public var fcpxml: URL?
        /// Nil unless the job was asked for them.
        public var words: URL?
        public var subtitles: URL?
        public var media: MediaInfo
        public var transcript: Transcript
        public var steps: [RenderStep]
        public var frames: Int
    }

    /// Cards and steps for a transcript on a timeline.
    public static func plan(_ transcript: Transcript, style: Style, frameRate: FrameRate) -> (steps: [RenderStep], frames: Int) {
        let cards = Cards.make(transcript.words, rules: style.cards)
        let steps = Cards.steps(cards, fps: frameRate.fps, minStep: style.cards.minStep)
        let frames = max(Int((transcript.duration * frameRate.fps).rounded()), steps.last?.last ?? 0)
        return (steps.map { RenderStep($0, textCase: style.textCase) }, frames)
    }

    /// Run the whole job. `progress` gets the phase and, while rendering, a fraction.
    public func run(progress: (@Sendable (Phase, Double) -> Void)? = nil) async throws -> Outputs {
        progress?(.probing, 0)
        let media = try await MediaInfo.probe(video)
        let transcript: Transcript
        if let t = self.transcript {
            transcript = t
        } else if let w = words {
            transcript = try Transcript.load(w)
        } else {
            progress?(.transcribing, 0)
            transcript = try await Transcriber.transcribe(video, locale: locale)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if writesWords, self.transcript != nil || words == nil || words!.standardizedFileURL != wordsURL.standardizedFileURL {
            try transcript.write(to: wordsURL)
        }
        let (steps, frames) = Job.plan(transcript, style: style, frameRate: media.frameRate)
        progress?(.rendering, 0)
        let size = Job.size(width: media.width, height: media.height, lines: lines)
        let renderer = Renderer(style: style, width: size.width, height: size.height)
        let writer = MovieWriter(renderer: renderer, frameRate: media.frameRate, frames: frames, codec: codec, quality: quality, matte: matte)
        try writer.write(steps, to: movieURL) { done, total in progress?(.rendering, Double(done) / Double(max(total, 1))) }
        progress?(.writing, 1)
        if writesSubtitles {
            let srt = Subtitles.srt(transcript, rules: style.cards, frameRate: media.frameRate)
            try srt.write(to: subtitlesURL, atomically: true, encoding: .utf8)
        }
        if writesFCPXML {
            let xml = FCPXML.document(name: name, movie: movieURL, frames: frames, frameRate: media.frameRate,
                                      width: media.width, height: media.height, movieWidth: size.width, movieHeight: size.height,
                                      background: background)
            try xml.write(to: fcpxmlURL, atomically: true, encoding: .utf8)
        }
        progress?(.done, 1)
        return Outputs(movie: movieURL, fcpxml: writesFCPXML ? fcpxmlURL : nil, words: writesWords ? wordsURL : nil,
                       subtitles: writesSubtitles ? subtitlesURL : nil, media: media, transcript: transcript, steps: steps, frames: frames)
    }
}
