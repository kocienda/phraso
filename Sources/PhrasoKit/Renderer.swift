// Drawing a card with Core Text and Core Graphics: glyph outlines grouped by word, the
// strokes outermost first with round joins (a centred stroke of twice the width, so the
// border reaches `width` outside the letter), then each word's fill, all inside one
// transparency layer so the shadow falls once from the composite. Units in the style
// are a 1920x1080 canvas, scaled to the output size.

import AppKit
import CoreText
import Foundation

/// One card ready to draw: its words already cased, and the frames it occupies.
public struct RenderStep: Equatable, Sendable {
    public var words: [String]
    public var highlight: Int
    public var first: Int
    public var last: Int

    public init(words: [String], highlight: Int, first: Int, last: Int) {
        self.words = words; self.highlight = highlight; self.first = first; self.last = last
    }

    public init(_ step: Step, textCase: TextCase) {
        self.init(words: step.card.words.map { textCase.apply($0.text) }, highlight: step.k, first: step.first, last: step.last)
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case fontNotFound(String)
    public var description: String {
        switch self { case .fontNotFound(let f): return "font not found: \(f) (a PostScript name; see Font Book)" }
    }
}

public struct Renderer {
    public var style: Style
    public var width: Int
    public var height: Int
    var scale: CGFloat { CGFloat(height) / 1080 }

    public init(style: Style, width: Int, height: Int) {
        self.style = style; self.width = width; self.height = height
    }

    /// Glyph outlines of one line of text, grouped by word, centred horizontally on the
    /// origin with the font's cap height centred vertically. The vertical anchor comes
    /// from the font, never from the glyphs drawn, so a comma or a descender cannot move
    /// the baseline between cards. `bounds` is the glyphs' horizontal extent over the
    /// font's fixed vertical band (descender to cap height).
    func wordPaths(_ words: [String]) throws -> (paths: [CGMutablePath], bounds: CGRect) {
        guard let font = NSFont(name: style.font, size: style.size * scale) else { throw RenderError.fontNotFound(style.font) }
        let text = words.joined(separator: " ")
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if style.tracking != 0 { attrs[.kern] = style.tracking * scale }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var wordOf: [Int] = []
        for (i, w) in words.enumerated() {
            wordOf.append(contentsOf: Array(repeating: i, count: w.utf16.count))
            if i + 1 < words.count { wordOf.append(i) }  // the space belongs to the word before it
        }
        let paths = words.map { _ in CGMutablePath() }
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            let runFont = unsafeBitCast(CFDictionaryGetValue(CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()), to: CTFont.self)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &indices)
            for g in 0..<n {
                var t = CGAffineTransform(translationX: positions[g].x, y: positions[g].y)
                if let p = CTFontCreatePathForGlyph(runFont, glyphs[g], &t) {
                    paths[wordOf[min(indices[g], wordOf.count - 1)]].addPath(p)
                }
            }
        }
        let all = CGMutablePath()
        paths.forEach { all.addPath($0) }
        let b = all.boundingBoxOfPath
        let cap = font.capHeight, descent = -font.descender
        let shift = CGAffineTransform(translationX: -b.midX, y: -cap / 2)
        let centred = paths.map { p -> CGMutablePath in let m = CGMutablePath(); m.addPath(p, transform: shift); return m }
        let band = CGRect(x: b.minX, y: -descent, width: b.width, height: cap + descent).applying(shift)
        return (centred, band)
    }

    /// How far into its pop a word is on frame `k` of its step: 1 once the pop is over,
    /// `from` on the first frame, eased with a slight overshoot between.
    public func popScale(frameInStep k: Int) -> CGFloat {
        guard let p = style.pop, p.frames > 0, k < p.frames else { return 1 }
        let t = CGFloat(k) / CGFloat(p.frames)
        let s: CGFloat = 1.4
        let u = t - 1
        let eased = 1 + (s + 1) * u * u * u + s * u * u  // back-out: 0 at t=0, peaks a little past 1, 1 at t=1
        return p.from + (1 - p.from) * eased
    }

    public func makeContext() -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// One card as an image, transparent or on mid grey.
    public func image(_ step: RenderStep, grey: Bool = false, pop: CGFloat = 1) throws -> CGImage {
        let ctx = makeContext()
        try draw(step, into: ctx, grey: grey, pop: pop)
        return ctx.makeImage()!
    }

    /// Clear `ctx` and draw one card into it. `ctx` is width x height device pixels, origin bottom-left.
    /// Over `background` if one is given (`grey`: mid grey, to look at).
    public func draw(_ step: RenderStep, into ctx: CGContext, grey: Bool = false, pop: CGFloat = 1, background: CGColor? = nil) throws {
        let W = width, H = height, s = style
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        if let bg = background ?? (grey ? CGColor(gray: 0.5, alpha: 1) : nil) {
            ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        var (paths, bounds) = try wordPaths(step.words)
        // the highlighted word may grow about the middle of its baseline, so the baseline holds
        let hs = s.highlightScale * pop
        if hs != 1, step.highlight >= 0, step.highlight < paths.count {
            let p = paths[step.highlight]
            let cx = p.boundingBoxOfPath.midX, base = -bounds.maxY  // the band's top is cap/2 above the origin; the baseline is cap/2 below
            let t = CGAffineTransform(translationX: cx, y: base).scaledBy(x: hs, y: hs).translatedBy(x: -cx, y: -base)
            let m = CGMutablePath(); m.addPath(p, transform: t); paths[step.highlight] = m
        }
        let origin = CGPoint(x: CGFloat(W) / 2 + s.position[0] * scale, y: CGFloat(H) / 2 + s.position[1] * scale)
        ctx.translateBy(x: origin.x, y: origin.y)
        if s.rotation != 0 { ctx.rotate(by: s.rotation * .pi / 180) }
        if s.flipH || s.flipV { ctx.scaleBy(x: s.flipH ? -1 : 1, y: s.flipV ? -1 : 1) }

        let all = CGMutablePath(); paths.forEach { all.addPath($0) }
        let outer = s.strokes.first?.width ?? 0

        if let sh = s.shadow {
            ctx.setShadow(offset: CGSize(width: sh.offset[0] * scale, height: sh.offset[1] * scale), blur: sh.blur * scale, color: sh.color.cgColor)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let box = s.box {
            let r = bounds.insetBy(dx: -(box.pad[0] + outer) * scale, dy: -(box.pad[1] + outer) * scale)
            ctx.setFillColor(box.color.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: box.radius * scale, cornerHeight: box.radius * scale, transform: nil))
            ctx.fillPath()
        }
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        for st in s.strokes {
            ctx.addPath(all)
            ctx.setStrokeColor(st.color.cgColor)
            ctx.setLineWidth(st.width * 2 * scale)  // a centred stroke: half lies outside the glyph
            ctx.strokePath()
        }
        for (i, p) in paths.enumerated() {
            ctx.addPath(p)
            ctx.setFillColor((i == step.highlight ? s.highlight : s.fill).cgColor)
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
    }
}

public func writePNG(_ img: CGImage, to url: URL) throws {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Phraso", code: 1, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
    }
    try data.write(to: url)
}
