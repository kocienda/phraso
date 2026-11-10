import XCTest
@testable import PhrasoKit

final class ExportTests: XCTestCase {
    func testSubtitlesAreOneCuePerCardOnFrames() {
        let t = Transcript(source: "t", duration: 6, locale: "en-US", words: words("Tug:0.5-0.9 uses:0.9-1.4 visuals.:1.4-2 Tell:5-5.5"))
        let srt = Subtitles.srt(t, rules: CardRules(words: 3), frameRate: FrameRate(num: 1001, den: 30000))
        XCTAssertEqual(srt, """
        1
        00:00:00,501 --> 00:00:02,402
        Tug uses visuals.

        2
        00:00:05,005 --> 00:00:05,906
        Tell


        """)
    }

    func testSizeScalesTheShorterSideAndKeepsSidesEven() {
        XCTAssert(Job.size(width: 3840, height: 2160, lines: nil) == (3840, 2160))
        XCTAssert(Job.size(width: 3840, height: 2160, lines: 2160) == (3840, 2160))
        XCTAssert(Job.size(width: 3840, height: 2160, lines: 1080) == (1920, 1080))
        XCTAssert(Job.size(width: 1080, height: 1920, lines: 720) == (720, 1280))
        XCTAssert(Job.size(width: 1918, height: 1080, lines: 721) == (1280, 722))
    }

    func testAScaledMovieGetsAFormatOfItsOwn() {
        let movie = URL(fileURLWithPath: "/tmp/a.mov")
        let same = FCPXML.document(name: "a", movie: movie, frames: 30, frameRate: .fps30, width: 3840, height: 2160)
        XCTAssertFalse(same.contains("id=\"r4\""))
        let half = FCPXML.document(name: "a", movie: movie, frames: 30, frameRate: .fps30, width: 3840, height: 2160,
                                   movieWidth: 1920, movieHeight: 1080)
        XCTAssert(half.contains("<format id=\"r4\" frameDuration=\"1/30s\" width=\"1920\" height=\"1080\""))
        XCTAssert(half.contains("format=\"r4\" videoSources"))
        XCTAssert(half.contains("<sequence format=\"r1\""))
    }

    func testAMatteFillsBehindTheCard() throws {
        let style = try Presets.style(named: "area")
        let r = Renderer(style: style, width: 320, height: 180)
        let ctx = r.makeContext()
        try r.draw(RenderStep(words: ["hi"], highlight: 0, first: 0, last: 1), into: ctx, background: Matte.green.color)
        let img = ctx.makeImage()!
        let px = img.dataProvider!.data! as Data
        // the top-left corner is far from the card: opaque green
        XCTAssertEqual(px[3], 255)
        XCTAssertEqual(Matte.clear.color, nil)
    }
}
