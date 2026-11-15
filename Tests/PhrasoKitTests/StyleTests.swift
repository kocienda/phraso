import CoreText
import XCTest
@testable import PhrasoKit

final class StyleTests: XCTestCase {
    private var folder: URL!

    /// Every test here gets its own presets folder, never the user's.
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phraso-presets-\(UUID().uuidString)")
        setenv("PHRASO_PRESETS", folder.path, 1)
    }

    override func tearDown() {
        unsetenv("PHRASO_PRESETS")
        try? FileManager.default.removeItem(at: folder)
    }

    func testColours() {
        XCTAssertEqual(Color("#4DF2F2")!.hex, "#4DF2F2")
        XCTAssertEqual(Color("#00000099")!.a, 0.6, accuracy: 0.002)
        XCTAssertEqual(Color("0.30 0.95 0.95 1")!.g, 0.95)
        XCTAssertNil(Color("#12"))
        XCTAssertEqual(Color.white.hex, "#FFFFFF")
    }

    func testShippedPresetsLoadAndRoundTrip() throws {
        let all = Presets.all()
        XCTAssertEqual(all.map(\.name), ["Outline", "Double Outline", "Classic", "Box", "Shadow"])
        XCTAssertEqual(Set(Presets.shippedFiles().keys), Set(Presets.shippedOrder))
        for s in all {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(Style.self, from: data), s, s.name)
        }
        let outline = try Presets.style(named: "outline")
        XCTAssertEqual(outline.strokes.first?.width, 22)
        XCTAssertEqual(outline.pop, Pop(frames: 3, from: 0.8))
        XCTAssertEqual(outline.cards.words, 3)
    }

    func testShippedPresetDeletedStaysDeleted() throws {
        XCTAssertEqual(Set(Presets.files().keys), Set(Presets.shippedOrder))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("box.json"))
        XCTAssertNil(Presets.files()["box"])
        XCTAssertEqual(try Presets.style(named: "box").name, "Box", "still found by name, as it ships")
    }

    /// Every shipped preset's font comes with macOS or ships in PhrasoKit, so a new
    /// install draws them all without installing a font.
    func testShippedFontsNeedNoInstall() throws {
        BundledFonts.register()
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Fonts", withExtension: nil))
        var bundled: Set<String> = []
        for u in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for d in (CTFontManagerCreateFontDescriptorsFromURL(u as CFURL) as? [CTFontDescriptor]) ?? [] {
                if let n = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String { bundled.insert(n) }
            }
        }
        for (stem, url) in Presets.shippedFiles() {
            let font = try Style.load(url).font
            if bundled.contains(font) { continue }
            let found = CTFontCreateWithName(font as CFString, 12, nil)
            let path = (CTFontCopyAttribute(found, kCTFontURLAttribute) as? URL)?.path ?? ""
            XCTAssertEqual(CTFontCopyPostScriptName(found) as String, font, stem)
            XCTAssertTrue(path.hasPrefix("/System/"), "\(stem): \(font) is neither bundled nor a macOS font (\(path))")
        }
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
        XCTAssertThrowsError(try JSONDecoder().decode(Style.self, from: Data(#"{"phraso": 2, "name": "X", "font": "Anton"}"#.utf8)))
    }

    func testUnknownPresetNamesTheOthers() {
        XCTAssertThrowsError(try Presets.style(named: "nope")) { e in
            XCTAssertTrue("\(e)".contains("outline"))
        }
    }
}
