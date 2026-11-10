// A job: one video in, one caption track out. The video's own size and frame rate set
// the timeline; the transcript comes from the file or from a words.json beside it.

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
    public var background: Background = .gap

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

    public struct Outputs: Sendable {
        public var movie: URL
        public var fcpxml: URL
        public var words: URL
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
        if self.transcript != nil || words == nil || words!.standardizedFileURL != wordsURL.standardizedFileURL {
            try transcript.write(to: wordsURL)
        }
        let (steps, frames) = Job.plan(transcript, style: style, frameRate: media.frameRate)
        progress?(.rendering, 0)
        let renderer = Renderer(style: style, width: media.width, height: media.height)
        let writer = MovieWriter(renderer: renderer, frameRate: media.frameRate, frames: frames, codec: codec)
        try writer.write(steps, to: movieURL) { done, total in progress?(.rendering, Double(done) / Double(max(total, 1))) }
        progress?(.writing, 1)
        let xml = FCPXML.document(name: name, movie: movieURL, frames: frames, frameRate: media.frameRate,
                                  width: media.width, height: media.height, background: background)
        try xml.write(to: fcpxmlURL, atomically: true, encoding: .utf8)
        progress?(.done, 1)
        return Outputs(movie: movieURL, fcpxml: fcpxmlURL, words: wordsURL, media: media, transcript: transcript, steps: steps, frames: frames)
    }
}
