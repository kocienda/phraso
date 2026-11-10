import XCTest
@testable import PhrasoKit

/// "tug:0.5-0.9 uses:0.9-1.4" -> [Word]
func words(_ spec: String) -> [Word] {
    spec.split(separator: " ").map { tok in
        let i = tok.lastIndex(of: ":")!
        let span = tok[tok.index(after: i)...].split(separator: "-")
        return Word(String(tok[..<i]), Double(span[0])!, Double(span[1])!)
    }
}

final class CardsTests: XCTestCase {
    func testBudgetBreaks() {
        let cards = Cards.make(words("a:0-1 b:1-2 c:2-3 d:3-4 e:4-5"), rules: CardRules(words: 3))
        XCTAssertEqual(cards.map { $0.words.map(\.text) }, [["a", "b", "c"], ["d", "e"]])
    }

    func testSentenceAndPauseBreak() {
        let cards = Cards.make(words("a:0-1 b.:1-2 c:2-3 d:4-5"), rules: CardRules(words: 4))
        XCTAssertEqual(cards.map { $0.words.map(\.text) }, [["a", "b."], ["c"], ["d"]])
    }

    func testClauseBreaksOnlyAfterTwoWords() {
        let cards = Cards.make(words("a,:0-1 b:1-2 c,:2-3 d:3-4"), rules: CardRules(words: 4))
        XCTAssertEqual(cards.map { $0.words.map(\.text) }, [["a,", "b", "c,"], ["d"]])
    }

    func testCardsAbutAcrossShortPausesAndDropAfterLongOnes() {
        let cards = Cards.make(words("a:0-1 b.:1-2 c:3-4 d.:4-5 e:9-10"), rules: CardRules(words: 4, linger: 1.5, hold: 0.4))
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].end, 3.0, accuracy: 1e-9)   // 1 s pause: stays up until c
        XCTAssertEqual(cards[1].end, 5.4, accuracy: 1e-9)   // 4 s pause: drops after hold
        XCTAssertEqual(cards[2].end, 10.4, accuracy: 1e-9)  // last card
    }

    func testStepsAbutToTheFrame() {
        let ws = words("a:0.016-0.35 b:0.35-0.683 c:0.683-1.016 d:1.016-1.349 e:1.349-1.682 f:1.682-2.0")
        let steps = Cards.steps(Cards.make(ws, rules: CardRules(words: 3)), fps: 30, minStep: 0.1)
        for (a, b) in zip(steps, steps.dropFirst()) { XCTAssertEqual(a.last, b.first) }
        XCTAssertEqual(steps.map(\.k), [0, 1, 2, 0, 1, 2])
    }

    func testShortWordSharesItsStepWithTheNext() {
        let ws = words("a:0-0.5 b:0.5-0.55 c:0.55-1.0")
        let steps = Cards.steps(Cards.make(ws, rules: CardRules(words: 3)), fps: 30, minStep: 0.1)
        XCTAssertEqual(steps.map(\.k), [0, 2])
        XCTAssertEqual(steps[1].first, 15)
    }

    func testFrameRates() {
        XCTAssertEqual(FrameRate(nearest: 29.97), FrameRate(num: 1001, den: 30000))
        XCTAssertEqual(FrameRate(nearest: 30), .fps30)
        XCTAssertEqual(FrameRate(nearest: 23.98).formatSuffix, "p2398")
        XCTAssertEqual(FrameRate.fps30.time(90), "90/30s")
        XCTAssertEqual(FrameRate(num: 1001, den: 30000).time(2), "2002/30000s")
        XCTAssertEqual(FrameRate.fps30.time(0), "0s")
    }
}
