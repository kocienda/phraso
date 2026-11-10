// The words as the recognizer heard them, each one editable, under a header that says
// what the document is doing. Click a word to move the playhead to it; the word under the
// playhead is marked. Tab and Shift-Tab go to the next and previous word, Return or
// leaving a word keeps the edit, Escape puts the word back as it was.

import AppKit
import Combine
import PhrasoKit

final class TranscriptView: NSView, NSCollectionViewDataSource {
    private let doc: Document
    private let progress = NSProgressIndicator()
    private let status = label(size: 12, secondary: true)
    private let chip = ExportChip()
    private let count = label(size: 12, secondary: true)
    private let retranscribe = NSButton(title: "Re-transcribe", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let words = NSCollectionView()
    private let flow = WordFlow()
    private let empty = label(size: 13, secondary: true)
    private var bag: Set<AnyCancellable> = []
    private var needsUpdate = false

    /// The words on show, which the cells are made from.
    private var shown: [Word] = []
    /// The word whose field has the keyboard, and its text as typed so far.
    private var editing: (index: Int, draft: String)?
    private var current: Int?

    init(doc: Document) {
        self.doc = doc
        super.init(frame: .zero)

        let title = Self.label(size: 13, secondary: false)
        title.font = .boldSystemFont(ofSize: 13)
        title.stringValue = "Transcript"
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 100).isActive = true
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retranscribe.target = self
        retranscribe.action = #selector(retranscribe(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, progress, status, chip, count, retranscribe])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        let line = NSBox()
        line.boxType = .separator

        flow.size = { [weak self] i in self?.size(of: i) ?? .zero }
        words.collectionViewLayout = flow
        words.dataSource = self
        words.isSelectable = false
        words.backgroundColors = [.clear]
        words.register(WordItem.self, forItemWithIdentifier: WordItem.id)
        scroll.documentView = words
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for v in [header, line, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: header.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        doc.$transcript.receive(on: DispatchQueue.main).sink { [weak self] t in
            self?.show(t?.words ?? [])
        }.store(in: &bag)
        doc.objectWillChange.sink { [weak self] in self?.setNeedsUpdate() }.store(in: &bag)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func label(size: CGFloat, secondary: Bool) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: size)
        if secondary { l.textColor = .secondaryLabelColor }
        return l
    }

    @objc private func retranscribe(_ sender: Any?) { doc.retranscribe() }

    // MARK: updates

    /// The published values change in `willSet`, so the header reads them on the next turn.
    private func setNeedsUpdate() {
        guard !needsUpdate else { return }
        needsUpdate = true
        DispatchQueue.main.async { [weak self] in
            self?.needsUpdate = false
            self?.update()
        }
    }

    private func update() {
        let busy = doc.isBusy
        progress.isHidden = !busy
        status.isHidden = !busy
        if busy {
            progress.isIndeterminate = doc.progress <= 0
            progress.doubleValue = doc.progress
            if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
            status.stringValue = doc.status
        } else {
            progress.stopAnimation(nil)
        }
        let movie = busy || doc.transcript == nil ? nil : doc.lastExport?.movie
        chip.movie = movie
        chip.isHidden = movie == nil
        count.isHidden = busy || doc.transcript == nil
        count.stringValue = "\(doc.transcript?.words.count ?? 0) words"
        retranscribe.isEnabled = doc.videoURL != nil && !busy

        scroll.isHidden = doc.transcript == nil
        empty.isHidden = doc.transcript != nil
        empty.stringValue = doc.videoURL == nil ? "No video yet." : "Transcribing…"

        let now = doc.currentWordIndex
        if now != current {
            let was = current
            current = now
            for i in [was, now].compactMap({ $0 }) { cell(i)?.current = i == now }
            if let now { reveal(now) }
        }
    }

    /// A new transcript is a new set of cells; a word edited, or put back by an undo, is
    /// the same cells with new text.
    private func show(_ new: [Word]) {
        if new.count == shown.count, zip(new, shown).allSatisfy({ $0.start == $1.start && $0.end == $1.end }) {
            shown = new
            for ip in words.indexPathsForVisibleItems() where ip.item != editing?.index {
                cell(ip.item)?.text = new[ip.item].text
            }
            flow.invalidateLayout()
            return
        }
        // the cells go, so a word half typed is dropped rather than written into words
        // it was not typed over
        editing = nil
        if let w = window, let f = w.firstResponder as? NSText, f.isDescendant(of: words) { w.makeFirstResponder(nil) }
        shown = new
        current = nil
        words.reloadData()
        setNeedsUpdate()
    }

    private func cell(_ i: Int) -> WordItem? {
        words.item(at: IndexPath(item: i, section: 0)) as? WordItem
    }

    /// The current word, scrolled to the middle when it is not already in sight.
    private func reveal(_ i: Int) {
        guard i < shown.count, let frame = flow.layoutAttributesForItem(at: IndexPath(item: i, section: 0))?.frame,
              !words.visibleRect.contains(frame) else { return }
        NSAnimationContext.runAnimationGroup { _ in
            words.animator().scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .centeredVertically)
        }
    }

    /// The old app's measure: wide enough for the text as typed, and never too small to click.
    private func size(of i: Int) -> NSSize {
        guard i < shown.count else { return .zero }
        let text = editing?.index == i ? editing!.draft : shown[i].text
        return NSSize(width: max(28, (CGFloat(text.count) * 8.5 + 14).rounded()), height: WordItem.height)
    }

    // MARK: data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shown.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: WordItem.id, for: indexPath) as! WordItem
        let i = indexPath.item
        item.index = i
        item.text = editing?.index == i ? editing!.draft : shown[i].text
        item.current = i == current
        item.began = { [weak self] in self?.began(i) }
        item.changed = { [weak self] s in self?.changed(i, s) }
        item.ended = { [weak self] s in self?.ended(i, s) }
        item.reverted = { [weak self] in self?.shown.indices.contains(i) == true ? self?.shown[i].text : nil }
        item.step = { [weak self] by in self?.focus(i + by) }
        return item
    }

    // MARK: editing

    private func began(_ i: Int) {
        guard i < shown.count else { return }
        editing = (i, shown[i].text)
        doc.time = shown[i].start + 0.01
    }

    private func changed(_ i: Int, _ s: String) {
        guard editing?.index == i else { return }
        editing?.draft = s
        flow.invalidateLayout()
    }

    private func ended(_ i: Int, _ s: String) {
        guard editing?.index == i else { return }
        editing = nil
        if i < shown.count, s != shown[i].text { doc.setWord(i, text: s) }
        flow.invalidateLayout()
    }

    private func focus(_ i: Int) {
        guard shown.indices.contains(i), let w = window else { return }
        let ip = IndexPath(item: i, section: 0)
        words.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        words.layoutSubtreeIfNeeded()
        if let item = cell(i) { w.makeFirstResponder(item.field) }
    }
}

/// Words wrap like text, from the left, 4 apart and 10 in from the edges.
final class WordFlow: NSCollectionViewLayout {
    var size: (Int) -> NSSize = { _ in .zero }
    private let spacing: CGFloat = 4
    private let inset: CGFloat = 10
    private var frames: [NSRect] = []
    private var height: CGFloat = 0
    private var width: CGFloat = 0

    override func prepare() {
        guard let cv = collectionView else { return }
        width = cv.enclosingScrollView?.contentSize.width ?? cv.bounds.width
        let n = cv.numberOfSections > 0 ? cv.numberOfItems(inSection: 0) : 0
        frames.removeAll(keepingCapacity: true)
        var x = inset, y = inset, rowH: CGFloat = 0
        for i in 0..<n {
            let s = size(i)
            if x + s.width > width - inset, x > inset { x = inset; y += rowH + spacing; rowH = 0 }
            frames.append(NSRect(origin: NSPoint(x: x, y: y), size: s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        height = n == 0 ? 0 : y + rowH + inset
    }

    override var collectionViewContentSize: NSSize { NSSize(width: width, height: height) }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // the frames run down the view, so the first one in the rect is found by halving
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var out: [NSCollectionViewLayoutAttributes] = []
        var i = lo
        while i < frames.count, frames[i].minY <= rect.maxY {
            if frames[i].intersects(rect) { out.append(attributes(i)) }
            i += 1
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != width
    }

    private func attributes(_ i: Int) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
        a.frame = frames[i]
        return a
    }
}

/// One word: a borderless field on a rounded tint, the accent's when it is under the playhead.
final class WordItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let id = NSUserInterfaceItemIdentifier("word")
    static let font = NSFont.systemFont(ofSize: 14)
    static let height = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 6

    let field = WordField()
    var index = 0
    var began: () -> Void = {}
    var changed: (String) -> Void = { _ in }
    var ended: (String) -> Void = { _ in }
    var reverted: () -> String? = { nil }
    var step: (Int) -> Void = { _ in }

    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    var current = false {
        didSet {
            guard current != oldValue else { return }
            field.font = current ? .systemFont(ofSize: 14, weight: .semibold) : Self.font
            (view as? WordCell)?.current = current
        }
    }

    override func loadView() {
        let cell = WordCell()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        field.began = { [weak self] in self?.began() }
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        view = cell
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // a field going out of sight keeps what was typed in it
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
    }

    func controlTextDidChange(_ obj: Notification) { changed(field.stringValue) }

    func controlTextDidEndEditing(_ obj: Notification) { ended(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): step(1); return true
        case #selector(NSResponder.insertBacktab(_:)): step(-1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if let old = reverted() {
                textView.string = old
                textView.selectAll(nil)
                changed(old)
            }
            return true
        default: return false
        }
    }
}

/// A word's field, which says when it takes the keyboard, by a click or by Tab.
final class WordField: NSTextField {
    var began: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { began() }
        return ok
    }
}

final class WordCell: NSView {
    var current = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (current ? NSColor.controlAccentColor.withAlphaComponent(0.25)
                                              : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
        }
    }
}

/// The movie the last Export wrote, to drag straight onto the Final Cut timeline: dropped
/// above a clip it connects there, with nothing to import first. It goes away at the next
/// edit, when the movie no longer shows what the document does.
final class ExportChip: NSView, NSDraggingSource {
    var movie: URL? {
        didSet { name.stringValue = movie?.lastPathComponent ?? "" }
    }
    private let name = NSTextField(labelWithString: "")
    private var down: NSEvent?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        let icon = NSImageView(image: NSImage(systemSymbolName: "film", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .labelColor
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, name])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        toolTip = "Drag onto the Final Cut timeline, above the clip it captions"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { down = event }

    override func mouseDragged(with event: NSEvent) {
        guard let movie, let start = down else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        down = nil
        let item = NSDraggingItem(pasteboardWriter: movie as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: movie.path))
        beginDraggingSession(with: [item], event: start, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
