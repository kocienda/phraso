import AppKit
import Combine
import PhrasoKit

private let sampleStep = RenderStep(words: ["ALL", "WITHOUT", "READING"], highlight: 1, first: 0, last: 1)

/// A thumbnail of a style: the sample card on dark grey, a 32:9 band drawn at half the
/// style's scale so the look reads at grid size.
func thumbnail(_ style: Style) -> CGImage? {
    var s = style
    s.position = [0, 0]
    s.size = min(s.size * 1.6, 170)
    let r = Renderer(style: s, width: 1920, height: 540)
    let ctx = r.makeContext()
    ctx.setFillColor(CGColor(gray: 0.28, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: r.width, height: r.height))
    guard let card = try? r.image(sampleStep) else { return nil }
    ctx.draw(card, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    return ctx.makeImage()
}

/// The measurements of Keynote's Format sidebar, read from its inspector nibs
/// (TMATextInspector, TMAPositionInspector, TMARotateInspector, TMAShadowDrop…,
/// TMAStrokeBasic…, TMATextSpacingInspector). Every pane here is laid out on them.
enum Pane {
    static let width: CGFloat = 270        // a pane
    static let margin: CGFloat = 16        // leading and trailing
    static let content: CGFloat = 238      // width - 2 * margin
    static let control: CGFloat = 24       // the height of a control row
    static let rowGap: CGFloat = 9         // between control rows
    static let titleTop: CGFloat = 13      // pane top to its title
    static let titleBottom: CGFloat = 12   // title to the first control
    static let bottom: CGFloat = 13        // last control to the pane's end
    static let field: CGFloat = 50         // a value field
    static let wideField: CGFloat = 65     // X, Y, Angle
    static let stepperGap: CGFloat = 3     // field to its stepper
    static let well = CGSize(width: 66, height: 23)
    static let slider: CGFloat = 151       // a slider beside a field and stepper
    static let label = NSFont.systemFont(ofSize: 13)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let caption = NSFont.systemFont(ofSize: 11)
    /// The sidebar's grey, under white fields and wells.
    static let background = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.925, alpha: 1)
    }
    /// The width a scroll bar takes when the system always shows them (none when they overlay).
    @MainActor static var scroller: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// A view that reads the style and shows it again whenever the style changes.
@MainActor protocol Refreshing: AnyObject {
    func refresh()
}

/// A view that dims with the controls in it, the way a disabled row does.
@MainActor protocol Enabling: AnyObject {
    var isEnabled: Bool { get set }
}

extension NSControl: Enabling {}

/// A view laid out top down, so a scroll view starts at its top.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A label in one of the pane's fonts.
@MainActor func paneLabel(_ s: String, font: NSFont = Pane.label, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

/// Pins a view to a size, either side left free when nil.
@discardableResult @MainActor func sized<V: NSView>(_ v: V, _ w: CGFloat?, _ h: CGFloat?) -> V {
    v.translatesAutoresizingMaskIntoConstraints = false
    if let w { v.widthAnchor.constraint(equalToConstant: w).isActive = true }
    if let h { v.heightAnchor.constraint(equalToConstant: h).isActive = true }
    return v
}

/// The presets over the inspector, on the sidebar's grey.
final class Sidebar: NSView {
    init(doc: Document) {
        super.init(frame: .zero)
        wantsLayer = true
        let grid = StyleGrid(doc: doc)
        let line = NSBox()
        line.boxType = .separator
        let inspector = StyleInspector(doc: doc)
        for v in [grid, line, inspector] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            v.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.heightAnchor.constraint(equalToConstant: 200),
            line.topAnchor.constraint(equalTo: grid.bottomAnchor),
            inspector.topAnchor.constraint(equalTo: line.bottomAnchor),
            inspector.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Pane.background.cgColor
        }
    }
}

// MARK: - The presets

/// The presets, as thumbnails. Click one to take its style.
final class StyleGrid: NSView {
    private let doc: Document
    private let scroll = NSScrollView()
    private let tiles = FlippedView()
    private var shown: [String] = []
    private var thumbs: [String: CGImage] = [:]
    private var bag: Set<AnyCancellable> = []
    private static let columnGap: CGFloat = 8, rowGap: CGFloat = 8, captionGap: CGFloat = 3, captionHeight: CGFloat = 14

    init(doc: Document) {
        self.doc = doc
        super.init(frame: .zero)
        let title = paneLabel("Styles", font: Pane.title)
        let folder = NSButton(title: "Presets Folder", target: self, action: #selector(revealPresets(_:)))
        folder.controlSize = .small
        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload Presets")!,
                              target: self, action: #selector(reloadPresets(_:)))
        reload.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, folder, reload])
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: Pane.titleTop, left: Pane.margin, bottom: Pane.titleBottom, right: Pane.margin)

        scroll.documentView = tiles
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        for v in [header, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        doc.$presets.combineLatest(doc.$presetName).receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refresh() }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func revealPresets(_ sender: Any?) { doc.revealPresets() }

    @objc private func reloadPresets(_ sender: Any?) {
        doc.reloadPresets()
        thumbs = [:]
        shown = []
        refresh()
    }

    private func refresh() {
        let stems = doc.presets.map(\.stem)
        if stems != shown {
            shown = stems
            tiles.subviews.forEach { $0.removeFromSuperview() }
            for p in doc.presets {
                if thumbs[p.stem] == nil { thumbs[p.stem] = thumbnail(p.style) }
                let stem = p.stem
                let tile = PresetTile(name: p.style.name, image: thumbs[p.stem])
                tile.chosen = { [weak self] in self?.doc.choosePreset(stem) }
                tiles.addSubview(tile)
            }
            needsLayout = true
        }
        for (tile, stem) in zip(tiles.subviews.compactMap { $0 as? PresetTile }, shown) {
            tile.isSelected = doc.presetName == stem
        }
    }

    /// Two columns across the pane, a 32:9 thumbnail over each name.
    override func layout() {
        super.layout()
        let width = scroll.contentSize.width
        let column = ((width - 2 * Pane.margin - Self.columnGap) / 2).rounded(.down)
        let thumb = (column * 9 / 32).rounded()
        let row = thumb + Self.captionGap + Self.captionHeight
        let n = tiles.subviews.count
        for (i, tile) in tiles.subviews.enumerated() {
            let x = Pane.margin + CGFloat(i % 2) * (column + Self.columnGap)
            let y = 2 + CGFloat(i / 2) * (row + Self.rowGap)
            tile.frame = NSRect(x: x, y: y, width: column, height: row)
        }
        let rows = CGFloat((n + 1) / 2)
        let height = n == 0 ? 0 : 2 + rows * row + (rows - 1) * Self.rowGap + Pane.bottom
        tiles.frame = NSRect(x: 0, y: 0, width: width, height: max(height, scroll.contentSize.height))
    }
}

/// One preset: its thumbnail, ringed in the accent colour while it is the style in use,
/// and its name under it.
final class PresetTile: FlippedView {
    var chosen: () -> Void = {}
    var isSelected = false { didSet { thumb.needsDisplay = true } }
    private let thumb = Thumb()
    private let name: NSTextField

    init(name: String, image: CGImage?) {
        self.name = paneLabel(name, font: Pane.caption)
        super.init(frame: .zero)
        self.name.alignment = .center
        thumb.layer?.contents = image
        thumb.tile = self
        addSubview(thumb)
        addSubview(self.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let h = bounds.height - 3 - 14
        thumb.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        name.frame = NSRect(x: 0, y: h + 3, width: bounds.width, height: 14)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { chosen() }
    }

    final class Thumb: NSView {
        weak var tile: PresetTile?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.masksToBounds = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = CGColor(gray: 0.28, alpha: 1)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.borderWidth = tile?.isSelected == true ? 2 : 0
                layer?.borderColor = NSColor.controlAccentColor.cgColor
            }
        }
    }
}

// MARK: - The inspector

/// Every field of the style, live, as a column of Keynote-style panes. Edits mark the
/// style as modified from its preset.
final class StyleInspector: NSView, NSTextFieldDelegate {
    private let doc: Document
    private let scroll = NSScrollView()
    private let column = FlippedView()
    private var refreshing: [Refreshing] = []
    private var bag: Set<AnyCancellable> = []
    private var needsRefresh = false

    private let nameField = NSTextField()
    private let star = paneLabel("*", font: .systemFont(ofSize: 17, weight: .bold))
    private let removeAdd = NSSegmentedControl()
    private let strokeRows = NSStackView()
    private var shownStrokes = -1
    private var shadowRows: [Enabling] = []
    private var boxRows: [Enabling] = []
    private var popRows: [Enabling] = []

    // What switching a part on gives it, and what its rows show, disabled, while it is
    // off: the rows stay where they are, so a getter must never unwrap the part.
    private static let newShadow = Shadow(color: Color(r: 0, g: 0, b: 0, a: 0.6), offset: [0, -6], blur: 12)
    private static let newBox = Box(color: Color(r: 0, g: 0, b: 0, a: 0.75), pad: [28, 14], radius: 18)
    private static let newPop = Pop(frames: 3, from: 0.8)

    init(doc: Document) {
        self.doc = doc
        super.init(frame: .zero)
        let panes = NSStackView(views: [
            presetPane(), rule(), fontPane(), rule(), colourPane(), rule(), borderPane(), rule(),
            shadowPane(), rule(), boxPane(), rule(), popPane(), rule(), positionPane(), rotatePane(), rule(), cardsPane(),
        ])
        panes.orientation = .vertical
        panes.alignment = .leading
        panes.spacing = 0
        panes.edgeInsets = NSEdgeInsets(top: 0, left: Pane.margin, bottom: 0, right: Pane.margin)
        panes.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(panes)

        scroll.documentView = column
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            column.widthAnchor.constraint(equalToConstant: Pane.width),
            panes.topAnchor.constraint(equalTo: column.topAnchor),
            panes.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        doc.$style.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.styleChanged() }.store(in: &bag)
        doc.$presetName.combineLatest(doc.$presets).sink { [weak self] _, _ in self?.setNeedsRefresh() }.store(in: &bag)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func styleChanged() {
        let r = doc.style.rotation
        // keep the field in -180...180 however the dial or the stepper turns
        if r > 180 || r <= -180 { doc.style.rotation = (r + 180).truncatingRemainder(dividingBy: 360) - 180 + (r <= -180 ? 360 : 0) }
        if let p = doc.presetName, let preset = doc.presets.first(where: { $0.stem == p })?.style, preset != doc.style { doc.presetName = nil }
        setNeedsRefresh()
    }

    private func setNeedsRefresh() {
        guard !needsRefresh else { return }
        needsRefresh = true
        DispatchQueue.main.async { [weak self] in
            self?.needsRefresh = false
            self?.refresh()
        }
    }

    private func refresh() {
        let s = doc.style
        if nameField.currentEditor() == nil, nameField.stringValue != s.name { nameField.stringValue = s.name }
        star.isHidden = doc.presetName != nil
        if s.strokes.count != shownStrokes { buildStrokeRows() }
        removeAdd.setEnabled(!s.strokes.isEmpty, forSegment: 0)
        removeAdd.setEnabled(s.strokes.count < 3, forSegment: 1)
        for r in refreshing { r.refresh() }
        for r in shadowRows { r.isEnabled = s.shadow != nil }
        for r in boxRows { r.isEnabled = s.box != nil }
        for r in popRows { r.isEnabled = s.pop != nil }
    }

    /// Keeps a view to be refreshed with the style.
    private func kept<V: Refreshing>(_ v: V) -> V {
        refreshing.append(v)
        return v
    }

    private func value(in range: ClosedRange<CGFloat>, step: CGFloat = 1, fraction: Int = 0, width: CGFloat = Pane.field,
                       suffix: String = "", stepperGap: CGFloat = Pane.stepperGap,
                       get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void) -> ValueField {
        kept(ValueField(in: range, step: step, fraction: fraction, width: width, suffix: suffix, stepperGap: stepperGap, get: get, set: set))
    }

    private func well(get: @escaping () -> PhrasoKit.Color, set: @escaping (PhrasoKit.Color) -> Void) -> ColorWell {
        kept(ColorWell(get: get, set: set))
    }

    private func slider(_ label: String, in range: ClosedRange<CGFloat>, suffix: String,
                        get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void) -> SliderRow {
        kept(SliderRow(label, field: value(in: range, suffix: suffix, get: get, set: set), in: range, get: get, set: set))
    }

    // MARK: panes

    /// The style's name in a well, the way Keynote names the paragraph style at the top
    /// of the Text pane; a star marks a preset edited away from its file.
    private func presetPane() -> NSView {
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.font = .systemFont(ofSize: 17, weight: .bold)
        nameField.placeholderString = "Style name"
        nameField.delegate = self
        nameField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let save = NSButton(title: "Save…", target: self, action: #selector(savePreset(_:)))
        save.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [nameField, star, spacer, save])
        row.spacing = 4
        row.setCustomSpacing(4, after: star)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        let well = RoundedWell()
        well.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        sized(well, Pane.content, 45)
        let pad = NSStackView(views: [well])
        pad.edgeInsets = NSEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        return pad
    }

    func controlTextDidChange(_ obj: Notification) {
        doc.style.name = nameField.stringValue
    }

    @objc private func savePreset(_ sender: Any?) { doc.savePreset() }

    private func fontPane() -> NSView {
        let doc = doc
        let font = kept(FontPicker(get: { (doc.style.font, doc.style.size) },
                                   setFont: { doc.style.font = $0 },
                                   size: value(in: 8...400, width: 55, suffix: "pt", get: { doc.style.size }, set: { doc.style.size = $0 })))
        let cases: [TextCase] = [.upper, .lower, .title, .asis]
        let segments = kept(Segments(["AA", "aa", "Aa", "Spoken"],
                                     get: { cases.firstIndex(of: doc.style.textCase) ?? -1 },
                                     set: { doc.style.textCase = cases[$0] }))
        segments.toolTip = "Letter case: all capitals, all lower case, title case, or as spoken"
        sized(segments, Pane.content, Pane.control)
        let tracking = LabelRow("Tracking", value(in: -5...20, suffix: "pt", get: { doc.style.tracking }, set: { doc.style.tracking = $0 }))
        return PaneStack("Font", [font, segments, tracking])
    }

    private func colourPane() -> NSView {
        let doc = doc
        return PaneStack(nil, [
            LabelRow("Text Color", well(get: { doc.style.fill }, set: { doc.style.fill = $0 })),
            LabelRow("Spoken Word", well(get: { doc.style.highlight }, set: { doc.style.highlight = $0 })),
            LabelRow("Spoken Scale", value(in: 100...140, suffix: "%",
                                           get: { doc.style.highlightScale * 100 }, set: { doc.style.highlightScale = $0 / 100 })),
        ])
    }

    /// One row per border the way Keynote lays out a stroke: which, colour, width.
    private func borderPane() -> NSView {
        removeAdd.segmentCount = 2
        removeAdd.trackingMode = .momentary
        removeAdd.controlSize = .small
        removeAdd.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove"), forSegment: 0)
        removeAdd.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), forSegment: 1)
        removeAdd.setToolTip("Remove the innermost border", forSegment: 0)
        removeAdd.setToolTip("Add a border inside the last one", forSegment: 1)
        removeAdd.segmentDistribution = .fillEqually
        removeAdd.target = self
        removeAdd.action = #selector(removeOrAdd(_:))
        sized(removeAdd, 44, nil)
        let title = paneLabel("Border", font: Pane.title)
        let header = sized(NSView(), Pane.content, Pane.control)
        for v in [title, removeAdd] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
            v.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true
        }
        title.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        removeAdd.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        strokeRows.orientation = .vertical
        strokeRows.alignment = .leading
        strokeRows.spacing = Pane.rowGap
        return PaneStack(nil, [header, strokeRows])
    }

    @objc private func removeOrAdd(_ control: NSSegmentedControl) {
        if control.selectedSegment == 0 {
            if !doc.style.strokes.isEmpty { doc.style.strokes.removeLast() }
        } else if doc.style.strokes.count < 3 {
            let first = doc.style.strokes.isEmpty
            doc.style.strokes.append(Stroke(color: first ? .black : Color(r: 0.92, g: 0.05, b: 0.05), width: first ? 22 : 10))
        }
    }

    /// The rows for the borders there are, made again when one is added or removed.
    private func buildStrokeRows() {
        let doc = doc
        let n = doc.style.strokes.count
        shownStrokes = n
        refreshing.removeAll { ($0 as? NSView)?.isDescendant(of: strokeRows) == true }
        strokeRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        strokeRows.isHidden = n == 0
        // one field of border `i`, safe to read after that border has been removed
        func get<T>(_ i: Int, _ field: KeyPath<Stroke, T>) -> () -> T {
            { (doc.style.strokes.indices.contains(i) ? doc.style.strokes[i] : Stroke(color: .black, width: 0))[keyPath: field] }
        }
        for i in 0..<n {
            let name = paneLabel(i == 0 ? "Outer" : (n > 2 && i == 1 ? "Middle" : "Inner"))
            let colour = well(get: get(i, \.color), set: { c in if doc.style.strokes.indices.contains(i) { doc.style.strokes[i].color = c } })
            let width = value(in: 0...40, width: 60, suffix: "pt", get: get(i, \.width),
                              set: { w in if doc.style.strokes.indices.contains(i) { doc.style.strokes[i].width = w } })
            strokeRows.addArrangedSubview(StrokeRow(name: name, well: colour, field: width))
        }
    }

    private func shadowPane() -> NSView {
        let doc = doc
        var shadow: Shadow { doc.style.shadow ?? Self.newShadow }
        let check = kept(CheckTitle("Shadow", get: { doc.style.shadow != nil }, set: { doc.style.shadow = $0 ? Self.newShadow : nil }))
        shadowRows = [
            slider("Blur", in: 0...40, suffix: "pt", get: { shadow.blur }, set: { doc.style.shadow?.blur = $0 }),
            slider("Offset", in: -20...20, suffix: "pt", get: { -shadow.offset[1] }, set: { doc.style.shadow?.offset = [shadow.offset[0], -$0] }),
            LabelRow("Color", well(get: { shadow.color }, set: { doc.style.shadow?.color = $0 })),
        ]
        return PaneStack(nil, [check] + shadowRows.map { $0 as! NSView })
    }

    private func boxPane() -> NSView {
        let doc = doc
        var box: Box { doc.style.box ?? Self.newBox }
        let check = kept(CheckTitle("Box", get: { doc.style.box != nil }, set: { doc.style.box = $0 ? Self.newBox : nil }))
        boxRows = [
            slider("Padding", in: 0...80, suffix: "pt", get: { box.pad[0] }, set: { doc.style.box?.pad = [$0, $0 / 2] }),
            slider("Corner Radius", in: 0...60, suffix: "pt", get: { box.radius }, set: { doc.style.box?.radius = $0 }),
            LabelRow("Color", well(get: { box.color }, set: { doc.style.box?.color = $0 })),
        ]
        return PaneStack(nil, [check] + boxRows.map { $0 as! NSView })
    }

    private func popPane() -> NSView {
        let doc = doc
        var pop: Pop { doc.style.pop ?? Self.newPop }
        let check = kept(CheckTitle("Pop In", get: { doc.style.pop != nil }, set: { doc.style.pop = $0 ? Self.newPop : nil }))
        popRows = [
            slider("Start Size", in: 30...100, suffix: "%", get: { pop.from * 100 }, set: { doc.style.pop?.from = $0 / 100 }),
            LabelRow("Frames", value(in: 1...12, get: { CGFloat(pop.frames) }, set: { doc.style.pop?.frames = Int($0) })),
        ]
        return PaneStack(nil, [check] + popRows.map { $0 as! NSView })
    }

    /// Keynote's Position pane: the title on the left, X and Y right-aligned with their
    /// names centred under the fields.
    private func positionPane() -> NSView {
        let x = Captioned("X", width: Pane.wideField, coordinate(0, in: -960...960))
        let y = Captioned("Y", width: Pane.wideField, coordinate(1, in: -540...540))
        return PaneStack("Position", gap: 10, [trailingRow([x, y], spacing: [9])])
    }

    /// One coordinate of the position, with a two-element array behind it.
    private func coordinate(_ i: Int, in range: ClosedRange<CGFloat>) -> ValueField {
        let doc = doc
        let fallback: CGFloat = i == 1 ? -380 : 0
        return value(in: range, width: Pane.wideField, suffix: "pt",
                     get: { doc.style.position.count > i ? doc.style.position[i] : fallback },
                     set: { v in
                         var p = doc.style.position
                         while p.count < 2 { p.append(p.count == 1 ? -380 : 0) }
                         p[i] = v
                         doc.style.position = p
                     })
    }

    /// Keynote's Rotate pane: knob, angle, and the two flips, with names underneath.
    private func rotatePane() -> NSView {
        let doc = doc
        let dial = kept(AngleDial(get: { doc.style.rotation }, set: { doc.style.rotation = $0 }))
        let dialBox = sized(NSView(), 32, Pane.control)
        dial.translatesAutoresizingMaskIntoConstraints = false
        dialBox.addSubview(dial)
        NSLayoutConstraint.activate([
            dial.centerXAnchor.constraint(equalTo: dialBox.centerXAnchor),
            dial.centerYAnchor.constraint(equalTo: dialBox.centerYAnchor),
        ])
        let angle = Captioned("Angle", width: Pane.wideField,
                              value(in: -180...180, width: Pane.wideField, suffix: "°", stepperGap: 6,
                                    get: { doc.style.rotation }, set: { doc.style.rotation = $0 }))
        let flips = NSStackView(views: [
            kept(FlipButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally",
                            get: { doc.style.flipH }, set: { doc.style.flipH = $0 })),
            kept(FlipButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertically",
                            get: { doc.style.flipV }, set: { doc.style.flipV = $0 })),
        ])
        flips.spacing = 6
        flips.setHuggingPriority(.required, for: .horizontal)
        let flip = Captioned("Flip", width: 80, flips)
        return PaneStack("Rotate", gap: 10, [trailingRow([dialBox, angle, flip], spacing: [11, 9])])
    }

    private func cardsPane() -> NSView {
        let doc = doc
        return PaneStack("Cards", [
            LabelRow("Words per Card", value(in: 1...8, get: { CGFloat(doc.style.cards.words) }, set: { doc.style.cards.words = Int($0) })),
            LabelRow("New Card after Pause", value(in: 0.2...2, step: 0.1, fraction: 1, suffix: "s",
                                                   get: { CGFloat(doc.style.cards.gap) }, set: { doc.style.cards.gap = Double($0) })),
            LabelRow("Clear after Pause", value(in: 0.5...4, step: 0.1, fraction: 1, suffix: "s",
                                                get: { CGFloat(doc.style.cards.linger) }, set: { doc.style.cards.linger = Double($0) })),
        ])
    }

    /// Views against the right margin, tops aligned, with the gaps given between them.
    private func trailingRow(_ views: [NSView], spacing: [CGFloat]) -> NSView {
        let row = NSStackView()
        row.alignment = .top
        row.setViews(views, in: .trailing)
        for (v, gap) in zip(views, spacing) { row.setCustomSpacing(gap, after: v) }
        return sized(row, Pane.content, nil)
    }

    /// The line between panes.
    private func rule() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return sized(b, Pane.content, 1)
    }
}

// MARK: - The pieces

/// A pane: an optional bold title, then control rows a fixed gap apart, with Keynote's
/// top and bottom margins.
final class PaneStack: NSStackView {
    init(_ title: String?, gap: CGFloat = Pane.rowGap, _ rows: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = gap
        edgeInsets = NSEdgeInsets(top: Pane.titleTop, left: 0, bottom: Pane.bottom, right: 0)
        if let title {
            let t = sized(paneLabel(title, font: Pane.title), nil, 16)
            addArrangedSubview(t)
            setCustomSpacing(gap == Pane.rowGap ? Pane.titleBottom : gap, after: t)
        }
        rows.forEach(addArrangedSubview)
        sized(self, Pane.content, nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The rounded tint the style's name sits in.
final class RoundedWell: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

/// A pane title that is also the switch for the pane (Keynote's Shadow, Reflection).
final class CheckTitle: NSButton, Refreshing {
    private let get: () -> Bool
    private let set: (Bool) -> Void

    init(_ text: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.get = get
        self.set = set
        super.init(frame: .zero)
        setButtonType(.switch)
        // the label sits a little further from the box than a plain checkbox's
        attributedTitle = NSAttributedString(string: "\u{2009}" + text, attributes: [.font: Pane.title])
        target = self
        action = #selector(toggled(_:))
        sized(self, nil, 16)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggled(_ sender: Any?) { set(state == .on) }

    func refresh() { state = get() ? .on : .off }
}

/// Label on the left, its control against the right margin, on one control row.
final class LabelRow: NSView, Enabling {
    private let name: NSTextField
    private let control: NSView

    init(_ label: String, _ control: NSView) {
        name = paneLabel(label)
        self.control = control
        super.init(frame: .zero)
        for v in [name, control] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            v.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8),
        ])
        sized(self, Pane.content, Pane.control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isEnabled = true {
        didSet {
            name.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
            (control as? Enabling)?.isEnabled = isEnabled
        }
    }
}

/// A border's row: its name, its colour centred in the space left, its width.
final class StrokeRow: NSView {
    init(name: NSTextField, well: NSView, field: NSView) {
        super.init(frame: .zero)
        let left = NSLayoutGuide(), right = NSLayoutGuide()
        addLayoutGuide(left)
        addLayoutGuide(right)
        for v in [name, well, field] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            v.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.widthAnchor.constraint(equalToConstant: 66),
            left.leadingAnchor.constraint(equalTo: name.trailingAnchor),
            well.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.leadingAnchor.constraint(equalTo: well.trailingAnchor),
            field.leadingAnchor.constraint(equalTo: right.trailingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        sized(self, Pane.content, Pane.control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Keynote's slider row: the name on its own line, then the slider with its field and
/// stepper against the right margin.
final class SliderRow: NSView, Refreshing, Enabling {
    private let name: NSTextField
    private let slider = NSSlider()
    private let field: ValueField
    private let get: () -> CGFloat
    private let set: (CGFloat) -> Void

    init(_ label: String, field: ValueField, in range: ClosedRange<CGFloat>, get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void) {
        name = paneLabel(label)
        self.field = field
        self.get = get
        self.set = set
        super.init(frame: .zero)
        slider.controlSize = .small
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slid(_:))
        for v in [name, slider, field] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.heightAnchor.constraint(equalToConstant: 16),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.widthAnchor.constraint(equalToConstant: Pane.slider),
            slider.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: name.bottomAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sized(self, Pane.content, 16 + Pane.control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func slid(_ sender: Any?) { set(CGFloat(slider.doubleValue)) }

    func refresh() { slider.doubleValue = Double(get()) }

    var isEnabled = true {
        didSet {
            name.textColor = isEnabled ? .labelColor : .tertiaryLabelColor
            slider.isEnabled = isEnabled
            field.isEnabled = isEnabled
        }
    }
}

/// A control with its name in small type centred beneath its first `width` points.
final class Captioned: NSView {
    init(_ caption: String, width: CGFloat, _ content: NSView) {
        super.init(frame: .zero)
        let label = paneLabel(caption, font: Pane.caption, color: .secondaryLabelColor)
        label.alignment = .center
        for v in [content, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.heightAnchor.constraint(equalToConstant: Pane.control),
            label.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: width),
            label.heightAnchor.constraint(equalToConstant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A number with its unit inside the field and a stepper beside it: Keynote's "120 pt".
/// The field also steps with the arrow keys, as Keynote's do: Up and Down move the value
/// by one step (ten with Shift) from whatever is typed, and leave it selected so the next
/// number typed replaces it.
final class ValueField: NSView, NSTextFieldDelegate, Refreshing, Enabling {
    let field = NSTextField()
    let stepper = NSStepper()
    private let range: ClosedRange<CGFloat>
    private let step: CGFloat
    private let formatter: NumberFormatter
    private let get: () -> CGFloat
    private let set: (CGFloat) -> Void

    /// The value the field last showed, which tells a change made elsewhere from one
    /// being typed.
    private var shown: CGFloat?

    init(in range: ClosedRange<CGFloat>, step: CGFloat = 1, fraction: Int = 0, width: CGFloat = Pane.field,
         suffix: String = "", stepperGap: CGFloat = Pane.stepperGap,
         get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void) {
        self.range = range
        self.step = step
        self.get = get
        self.set = set
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        f.isLenient = true
        let unit = suffix.isEmpty ? "" : (suffix == "°" || suffix == "%" ? suffix : " " + suffix)
        f.positiveSuffix = unit
        f.negativeSuffix = unit
        formatter = f
        super.init(frame: .zero)

        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.alignment = .right
        field.formatter = formatter
        field.delegate = self
        field.target = self
        field.action = #selector(commit(_:))
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(step)
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped(_:))
        for v in [field, stepper] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.widthAnchor.constraint(equalToConstant: width),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            stepper.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: stepperGap),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Pane.control),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            stepper.isEnabled = isEnabled
            // a stepper draws its arrows as they were when its value was last set, so one
            // switched back on is given its value again
            let v = stepper.doubleValue
            stepper.doubleValue = v == stepper.maxValue ? stepper.minValue : stepper.maxValue
            stepper.doubleValue = v
        }
    }

    func refresh() {
        let v = get()
        stepper.doubleValue = Double(v)
        // a field being typed in keeps its text, unless the value is changed from
        // elsewhere (a preset chosen, an undo); the field writes its own changes
        guard v != shown else { return }
        shown = v
        if let editor = field.currentEditor() {
            editor.string = formatter.string(from: NSNumber(value: Double(v))) ?? ""
            editor.selectAll(nil)
        } else {
            field.objectValue = NSNumber(value: Double(v))
        }
    }

    private func clamp(_ v: CGFloat) -> CGFloat { min(max(v, range.lowerBound), range.upperBound) }

    @objc private func commit(_ field: NSTextField) {
        let v = clamp(CGFloat(field.doubleValue))
        shown = v
        set(v)
        field.objectValue = NSNumber(value: Double(v))
    }

    @objc private func stepped(_ stepper: NSStepper) {
        let v = clamp(CGFloat(stepper.doubleValue))
        shown = v
        set(v)
        let text = formatter.string(from: NSNumber(value: Double(v))) ?? ""
        if let editor = field.currentEditor() { editor.string = text } else { field.objectValue = NSNumber(value: Double(v)) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let direction: CGFloat
        var steps: CGFloat = 1
        switch selector {
        case #selector(NSResponder.moveUp(_:)): direction = 1
        case #selector(NSResponder.moveDown(_:)): direction = -1
        case #selector(NSResponder.moveUpAndModifySelection(_:)): direction = 1; steps = 10
        case #selector(NSResponder.moveDownAndModifySelection(_:)): direction = -1; steps = 10
        default: return false
        }
        let typed = formatter.number(from: textView.string).map { CGFloat($0.doubleValue) }
        let v = clamp((typed ?? get()) + direction * steps * step)
        shown = v
        set(v)
        textView.string = formatter.string(from: NSNumber(value: Double(v))) ?? ""
        textView.selectAll(nil)
        return true
    }
}

/// A segmented control that stays the width it is given, in equal segments.
final class Segments: NSSegmentedControl, Refreshing {
    private let get: () -> Int
    private let set: (Int) -> Void

    init(_ labels: [String], get: @escaping () -> Int, set: @escaping (Int) -> Void) {
        self.get = get
        self.set = set
        super.init(frame: .zero)
        segmentCount = labels.count
        for (i, l) in labels.enumerated() { setLabel(l, forSegment: i) }
        trackingMode = .selectOne
        segmentDistribution = .fillEqually
        target = self
        action = #selector(changed(_:))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed(_ sender: Any?) {
        if (0..<segmentCount).contains(selectedSegment) { set(selectedSegment) }
    }

    func refresh() { selectedSegment = get() }
}

/// A colour well at Keynote's size: the swatch opens the palette, the wheel the panel.
final class ColorWell: NSColorWell, Refreshing {
    private let get: () -> PhrasoKit.Color
    private let set: (PhrasoKit.Color) -> Void

    init(get: @escaping () -> PhrasoKit.Color, set: @escaping (PhrasoKit.Color) -> Void) {
        self.get = get
        self.set = set
        super.init(frame: NSRect(origin: .zero, size: Pane.well))
        colorWellStyle = .expanded
        supportsAlpha = true
        target = self
        action = #selector(changed(_:))
        sized(self, Pane.well.width, Pane.well.height)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed(_ sender: Any?) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        set(PhrasoKit.Color(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent))
    }

    func refresh() {
        let c = get()
        let ns = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        if color != ns { color = ns }
    }
}

/// One of Keynote's two flip buttons: 37 by 24, lit while the flip is on.
final class FlipButton: NSButton, Refreshing {
    private let get: () -> Bool
    private let set: (Bool) -> Void

    init(symbol: String, help: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.get = get
        self.set = set
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        bezelStyle = .push
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        imagePosition = .imageOnly
        toolTip = help
        target = self
        action = #selector(toggled(_:))
        sized(self, 37, Pane.control)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggled(_ sender: Any?) { set(state == .on) }

    func refresh() { state = get() ? .on : .off }
}

/// Keynote's rotation knob: drag the handle round; the angle is where it points.
final class AngleDial: FlippedView, Refreshing {
    private let get: () -> CGFloat
    private let set: (CGFloat) -> Void
    private let d: CGFloat = 24

    init(get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void) {
        self.get = get
        self.set = set
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        toolTip = "Drag to rotate"
        sized(self, d, d)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        circle.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        // the handle starts on the left and turns with the card, anticlockwise for a
        // positive angle (the view is flipped, so that is a negative turn here)
        let t = NSAffineTransform()
        t.translateX(by: d / 2, yBy: d / 2)
        t.rotate(byDegrees: -get())
        t.concat()
        let w = d * 0.4, h: CGFloat = 2.5
        NSColor.labelColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: -d * 0.22 - w / 2, y: -h / 2, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }

    override func mouseDown(with event: NSEvent) { turn(event) }
    override func mouseDragged(with event: NSEvent) { turn(event) }

    private func turn(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let v = CGPoint(x: p.x - d / 2, y: p.y - d / 2)
        guard hypot(v.x, v.y) > 2 else { return }
        // the angle that turns the handle to point at the pointer
        let a = atan2(v.y, -v.x) * 180 / .pi
        set((a / 5).rounded() * 5)
    }
}
