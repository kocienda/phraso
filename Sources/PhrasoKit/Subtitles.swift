// SubRip subtitles from the same cards the movie shows: one cue per card, in the words
// as spoken, on and off on the video's own frames, for a player or a site that shows
// captions of its own.

import Foundation

public enum Subtitles {
    /// The `.srt` text for a transcript.
    public static func srt(_ transcript: Transcript, rules: CardRules, frameRate fr: FrameRate) -> String {
        let cards = Cards.make(transcript.words, rules: rules)
        var out = ""
        var n = 0
        for card in cards {
            let first = Int((card.start * fr.fps).rounded()), last = Int((card.end * fr.fps).rounded())
            guard last > first else { continue }
            n += 1
            out += "\(n)\n\(stamp(first, fr)) --> \(stamp(last, fr))\n"
            out += card.words.map(\.text).joined(separator: " ") + "\n\n"
        }
        return out
    }

    /// Frame f as `HH:MM:SS,mmm`.
    static func stamp(_ f: Int, _ fr: FrameRate) -> String {
        let ms = Int((Double(f * fr.num) * 1000 / Double(fr.den)).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
