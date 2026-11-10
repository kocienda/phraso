import XCTest
@testable import PhraseoKit

final class StyleTests: XCTestCase {
    func testColours() {
        XCTAssertEqual(Color("#4DF2F2")!.hex, "#4DF2F2")
        XCTAssertEqual(Color("#00000099")!.a, 0.6, accuracy: 0.002)
        XCTAssertEqual(Color("0.30 0.95 0.95 1")!.g, 0.95)
        XCTAssertNil(Color("#12"))
        XCTAssertEqual(Color.white.hex, "#FFFFFF")
    }

    func testShippedPresetsLoadAndRoundTrip() throws {
        let all = Presets.all()
        XCTAssertEqual(Set(all.map(\.name)), ["Area", "Glanceable", "Yellow", "Boxed", "Clean"])
        for s in all {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(Style.self, from: data), s, s.name)
        }
        let area = try Presets.style(named: "area")
        XCTAssertEqual(area.strokes.first?.width, 22)
        XCTAssertEqual(area.pop, Pop(frames: 3, from: 0.8))
        XCTAssertEqual(area.cards.words, 3)
    }

    func testMinimalPresetGetsDefaults() throws {
        let s = try JSONDecoder().decode(Style.self, from: Data(#"{"name": "X", "font": "Anton"}"#.utf8))
        XCTAssertEqual(s.size, 96)
        XCTAssertEqual(s.textCase, .upper)
        XCTAssertEqual(s.position, [0, -380])
        XCTAssertEqual(s.rotation, 0)
        XCTAssertFalse(s.flipH || s.flipV)
        XCTAssertEqual(s.cards, CardRules())
        XCTAssertNil(s.pop)
    }

    func testNewerFormatIsRefused() {
        XCTAssertThrowsError(try JSONDecoder().decode(Style.self, from: Data(#"{"phraseo": 2, "name": "X", "font": "Anton"}"#.utf8)))
    }

    func testUnknownPresetNamesTheOthers() {
        XCTAssertThrowsError(try Presets.style(named: "nope")) { e in
            XCTAssertTrue("\(e)".contains("area"))
        }
    }
}
