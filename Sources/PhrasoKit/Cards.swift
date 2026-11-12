// Cards and steps. A card is a few words shown together; a step is one card with one
// word highlighted, on a span of whole frames. Steps abut: there are no blank frames
// between words of a card, and cards hold until the next one unless the pause is long.

import Foundation

/// How the transcript is cut into cards. Times in seconds.
public struct CardRules: Codable, Equatable, Sendable {
    /// At most this many words on a card.
    public var words: Int = 3
    /// A pause longer than this starts a new card.
    public var gap: Double = 0.6
    /// Cards abut unless the pause before the next one is longer than this.
    public var linger: Double = 1.5
    /// How long a card stays after its last word when it does drop.
    public var hold: Double = 0.4
    /// A word shorter than this shares its step with the next word.
    public var minStep: Double = 0.1

    public init(words: Int = 3, gap: Double = 0.6, linger: Double = 1.5, hold: Double = 0.4, minStep: Double = 0.1) {
        self.words = words; self.gap = gap; self.linger = linger; self.hold = hold; self.minStep = minStep
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 3
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? 0.6
        linger = try c.decodeIfPresent(Double.self, forKey: .linger) ?? 1.5
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? 0.4
        minStep = try c.decodeIfPresent(Double.self, forKey: .minStep) ?? 0.1
    }
}

public struct Card: Equatable, Sendable {
    public var words: [Word]
    /// When the card leaves, after its last word.
    public var end: Double
    public var start: Double { words[0].start }
}

public struct Step: Equatable, Sendable {
    public var card: Card
    /// The highlighted word.
    public var k: Int
    /// First frame.
    public var first: Int
    /// Last frame, exclusive.
    public var last: Int

    public func text(_ textCase: TextCase) -> String {
        textCase.apply(card.words.map(\.text).joined(separator: " "))
    }
}

public enum TextCase: String, Codable, Sendable, CaseIterable {
    case upper, lower, title, asis

    public func apply(_ s: String) -> String {
        switch self {
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .title: return s.capitalized
        case .asis: return s
        }
    }
}

private let closers: Set<Character> = ["'", "\"", ")"]
private func endsWith(_ text: String, anyOf marks: Set<Character>) -> Bool {
    var s = Substring(text)
    while let c = s.last, closers.contains(c) { s = s.dropLast() }
    return s.last.map { marks.contains($0) } ?? false
}
private let sentenceMarks: Set<Character> = [".", "!", "?", "…"]
private let clauseMarks: Set<Character> = [",", ";", ":", "—"]

public enum Cards {
    /// Group words into cards of at most `rules.words`, breaking at sentence and clause
    /// punctuation, at pauses longer than `gap`, and after a word that carries a break,
    /// whatever the count. Cards abut: a card stays up until the next card's first word,
    /// so there are no blank frames mid-speech. Only when the pause before the next card
    /// is longer than `linger` (or there is no next card) does it drop `hold` seconds
    /// after its last word.
    public static func make(_ words: [Word], rules r: CardRules) -> [Card] {
        var cards: [Card] = []
        var current: [Word] = []
        for (i, w) in words.enumerated() {
            current.append(w)
            let next: Word? = i + 1 < words.count ? words[i + 1] : nil
            let full = current.count >= r.words
            let pause = next.map { $0.start - w.end > r.gap } ?? false
            let sentence = endsWith(w.text, anyOf: sentenceMarks)
            let clause = endsWith(w.text, anyOf: clauseMarks) && current.count >= 2
            if next == nil || full || pause || sentence || clause || w.break {
                cards.append(Card(words: current, end: 0))
                current = []
            }
        }
        for i in cards.indices {
            let last = cards[i].words[cards[i].words.count - 1].end
            let next: Double? = i + 1 < cards.count ? cards[i + 1].start : nil
            if let n = next, n - last <= r.linger {
                cards[i].end = n
            } else if let n = next {
                cards[i].end = min(last + r.hold, n)
            } else {
                cards[i].end = last + r.hold
            }
        }
        return cards
    }

    /// One step per word, cut on whole frames so neighbours abut exactly. A word shorter
    /// than `minStep` shares its step with the next word.
    public static func steps(_ cards: [Card], fps: Double, minStep: Double) -> [Step] {
        var steps: [Step] = []
        for var card in cards {
            let n = card.words.count
            var k = 0
            while k < n {
                let start = k == 0 ? card.start : card.words[k].start
                let end = k + 1 < n ? card.words[k + 1].start : card.end
                if end - start < minStep && k + 1 < n {
                    card.words[k + 1].start = start
                    k += 1
                    continue
                }
                let first = Int((start * fps).rounded()), last = Int((end * fps).rounded())
                if last > first { steps.append(Step(card: card, k: k, first: first, last: last)) }
                k += 1
            }
        }
        return steps
    }
}
