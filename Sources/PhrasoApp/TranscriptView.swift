// The words as the recognizer heard them, each one editable, under a header that says
// what the document is doing. Click a word to move the playhead to it; the word under the
// playhead is marked. Tab and Shift-Tab go to the next and previous word. Return, Escape
// and leaving a word all keep the edit, and Return and Escape also let go of the keyboard,
// so space plays again; Undo is the way back to the word as it was.

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
    private let words = WordCollection()
    private let flow = WordFlow()
    private let empty = label(size: 13, secondary: true)
    private var bag: Set<AnyCancellable> = []
    private var needsUpdate = false

    /// The words on show, which the cells are made from.
    private var shown: [Word] = []
    /// The word whose field has the keyboard, and its text as typed so far.
    private var editing: (index: Int, draft: String)?
    private var current: Int?
    /// The word last taken out, so the word being edited when the cells are made again
    /// can be found at its new place; and the word to take the keyboard then, when Delete
    /// took the word out.
    private var removed: Int?
    private var refocus: Int?
    /// Each text's width as the field draws it in semibold, which the layout asks for
    /// on every pass.
    private var widths: [String: CGFloat] = [:]

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
        words.gap = { [weak self] p in self?.flow.gap(at: p) }
        words.insert = { [weak self] i in self?.insert(at: i) }
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

        // the latest transcript rather than the one delivered, so a click that takes an
        // empty word out and puts a new one in is one reload
        doc.$transcript.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.show(self?.doc.transcript?.words ?? [])
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
            for ip in words.indexPathsForVisibleItems() { cell(ip.item)?.breaks = new[ip.item].break }
            flow.invalidateLayout()
            return
        }
        // a word just taken out leaves the keyboard with the word after it, or with the
        // word that had been clicked as the empty one let go
        var target = refocus
        if target == nil, let e = editing, let r = removed { target = e.index > r ? e.index - 1 : e.index }
        refocus = nil
        removed = nil
        // the cells go, so a word half typed is dropped rather than written into words
        // it was not typed over
        editing = nil
        if let w = window, let f = w.firstResponder as? NSText, f.isDescendant(of: words) { w.makeFirstResponder(nil) }
        shown = new
        current = nil
        words.reloadData()
        setNeedsUpdate()
        if let target { focus(target) }
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

    /// Wide enough for the text as typed, measured as the field draws it in the semibold
    /// the word under the playhead takes, so it does not clip, plus the field's insets.
    /// The field's own padding, inside that measure, leaves room for the caret at the
    /// end, and a word that ends its card has room for the mark that says so. Never too
    /// small to click.
    private func size(of i: Int) -> NSSize {
        guard i < shown.count else { return .zero }
        let text = editing?.index == i ? editing!.draft : shown[i].text
        let mark = shown[i].break ? WordItem.markWidth : 0
        return NSSize(width: max(28, width(of: text) + 2 * WordItem.inset + mark), height: WordItem.height)
    }

    private static let measure: NSTextFieldCell = {
        let c = NSTextFieldCell(textCell: "")
        c.isBordered = false
        c.drawsBackground = false
        c.font = WordItem.currentFont
        return c
    }()

    private func width(of text: String) -> CGFloat {
        if let w = widths[text] { return w }
        Self.measure.stringValue = text
        let w = ceil(Self.measure.cellSize.width)
        widths[text] = w
        return w
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
        item.breaks = shown[i].break
        item.began = { [weak self] in self?.began(i) }
        item.changed = { [weak self] s in self?.changed(i, s) }
        item.ended = { [weak self] s in self?.ended(i, s) }
        item.remove = { [weak self] in self?.remove(i, focusNext: true) }
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
        guard i < shown.count else { return }
        // a word left empty goes, however its editing ended
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return remove(i, focusNext: false) }
        if s != shown[i].text { doc.setWord(i, text: s) }
        flow.invalidateLayout()
    }

    /// Takes word `i` out. After Delete the next word takes the keyboard, selected, or
    /// the one before when it was the last; the new cells are made first.
    private func remove(_ i: Int, focusNext: Bool) {
        guard i < shown.count else { return }
        editing = nil
        removed = i
        refocus = focusNext && shown.count > 1 ? min(i, shown.count - 2) : nil
        doc.removeWord(i)
    }

    /// Ends the card after word `i`, or lets it run on, keeping the word in the keyboard.
    /// What was typed is kept first, as leaving the word would keep it; a word with
    /// nothing in it has nothing to end a card on.
    private func toggleBreak(_ i: Int) {
        guard i < shown.count else { return }
        let text = editing?.index == i ? editing!.draft : shown[i].text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if text != shown[i].text { doc.setWord(i, text: text) }
        doc.toggleBreak(i)
    }

    /// The word Edit ▸ Add Card Break acts on: the one being typed in, or else the one
    /// under the playhead.
    private var breakTarget: Int? {
        let i = editing?.index ?? doc.currentWordIndex
        return i.flatMap { shown.indices.contains($0) ? $0 : nil }
    }

    /// Whether the word Add Card Break acts on already ends its card; nil when there is
    /// no such word or it has no text, which turns the item off.
    func breakState() -> Bool? {
        guard !scroll.isHidden, let i = breakTarget else { return nil }
        let text = editing?.index == i ? editing!.draft : shown[i].text
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : shown[i].break
    }

    func toggleBreakOnTarget() {
        if let i = breakTarget { toggleBreak(i) }
    }

    /// Puts an empty word in at gap `i`, counted in the words on show, and gives it the
    /// keyboard once its cell is made. The click that asks may have just let go of an
    /// empty word, which takes it out and moves the gap down by one.
    private func insert(at i: Int) {
        var at = i
        if let r = removed, r < at { at -= 1 }
        removed = nil
        refocus = at
        doc.insertWord(at: at)
    }

    private func focus(_ i: Int) {
        guard shown.indices.contains(i), let w = window else { return }
        let ip = IndexPath(item: i, section: 0)
        words.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        words.layoutSubtreeIfNeeded()
        if let item = cell(i) { w.makeFirstResponder(item.field) }
    }

    /// The first word, selected and taking the keyboard, which is where Return goes when
    /// nothing else has it. False when there are no words.
    @discardableResult
    func focusFirstWord() -> Bool {
        guard !shown.isEmpty, !scroll.isHidden else { return false }
        focus(0)
        return cell(0)?.field.currentEditor() != nil
    }
}

/// Words wrap like text, from the left, 8 apart (room to click between two) and 10 in
/// from the edges.
final class WordFlow: NSCollectionViewLayout {
    var size: (Int) -> NSSize = { _ in .zero }
    private let spacing: CGFloat = 8
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

    /// The gap under a point: between two words on a row, or just before the first or
    /// after the last on it. The index is where a word put in there goes, and the bar is
    /// where the insertion mark is drawn.
    func gap(at p: NSPoint) -> (index: Int, bar: NSRect)? {
        let row = frames.indices.filter { frames[$0].minY <= p.y && p.y <= frames[$0].maxY }
        guard let first = row.first, let last = row.last,
              !row.contains(where: { frames[$0].contains(p) }) else { return nil }
        let x: CGFloat, index: Int
        if p.x < frames[first].minX {
            (x, index) = (frames[first].minX - spacing / 2, first)
        } else if p.x > frames[last].maxX {
            guard p.x <= frames[last].maxX + spacing + 4 else { return nil }
            (x, index) = (frames[last].maxX + spacing / 2, last + 1)
        } else {
            guard let next = row.first(where: { frames[$0].minX > p.x }) else { return nil }
            (x, index) = ((frames[next - 1].maxX + frames[next].minX) / 2, next)
        }
        let top = row.map { frames[$0].minY }.min()!, bottom = row.map { frames[$0].maxY }.max()!
        return (index, NSRect(x: (x - 1).rounded(), y: top, width: 2, height: bottom - top))
    }

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

/// The words' view, which puts a word in where a click lands between two, and marks the
/// place with a bar while the pointer is over it.
final class WordCollection: NSCollectionView {
    var gap: (NSPoint) -> (index: Int, bar: NSRect)? = { _ in nil }
    var insert: (Int) -> Void = { _ in }
    private let bar = InsertionBar()
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let g = gap(convert(event.locationInWindow, from: nil)) else { bar.isHidden = true; return }
        bar.frame = g.bar
        // the cells come and go, so the bar is put back on top of them each time
        addSubview(bar, positioned: .above, relativeTo: nil)
        bar.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        bar.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let g = gap(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        bar.isHidden = true
        insert(g.index)
    }
}

final class InsertionBar: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    // the bar is a mark, not a target: clicks go through to the gap under it
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One word: a borderless field on a rounded tint, the accent's when it is under the playhead.
final class WordItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let id = NSUserInterfaceItemIdentifier("word")
    static let font = NSFont.systemFont(ofSize: 14)
    static let currentFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let height = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 6
    /// The field's distance in from each side of the chip. The field pads its text by 2
    /// more, so the text sits 6 in.
    static let inset: CGFloat = 4
    static let markFont = NSFont.systemFont(ofSize: 11)
    /// The room the ⏎ takes at the right of a word that ends its card.
    static let markWidth: CGFloat = ceil(("⏎" as NSString).size(withAttributes: [.font: markFont]).width) + 2

    let field = WordField()
    private let mark = NSTextField(labelWithString: "⏎")
    private var fieldEnd: NSLayoutConstraint!
    var index = 0
    var began: () -> Void = {}
    var changed: (String) -> Void = { _ in }
    var ended: (String) -> Void = { _ in }
    var remove: () -> Void = {}
    var step: (Int) -> Void = { _ in }

    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    var current = false {
        didSet {
            guard current != oldValue else { return }
            field.font = current ? Self.currentFont : Self.font
            (view as? WordCell)?.current = current
        }
    }

    /// Whether the word ends its card, shown by a ⏎ at the chip's right edge.
    var breaks = false {
        didSet {
            guard breaks != oldValue else { return }
            mark.isHidden = !breaks
            fieldEnd.constant = -(Self.inset + (breaks ? Self.markWidth : 0))
        }
    }

    override func loadView() {
        let cell = WordCell()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Self.font
        field.lineBreakMode = .byClipping
        // the chip is wide enough for the word in semibold, so a word in the regular
        // weight is centred in it rather than leaving all the slack on its right
        field.alignment = .center
        field.cell?.isScrollable = true
        field.delegate = self
        field.began = { [weak self] in self?.began() }
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        mark.font = Self.markFont
        mark.textColor = .secondaryLabelColor
        mark.isHidden = true
        mark.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(mark)
        fieldEnd = field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.inset)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.inset),
            fieldEnd,
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            mark.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.inset),
            mark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.cancelOperation(_:)):
            // the edit is kept either way, and ends with nothing holding the keyboard
            control.window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            // Delete on the whole word takes the word out, not just its letters
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            guard all.length > 0, textView.selectedRange() == all else { return false }
            remove()
            return true
        default: return false
        }
    }
}

/// A word's field, which says when it takes the keyboard, by a click or by Tab. The first
/// click selects the whole word, as Tab does; a click in a word already being edited
/// places the caret.
final class WordField: NSTextField {
    var began: () -> Void = {}
    /// The click that gave this field the keyboard. The window makes a clicked field
    /// first responder before it passes the click on, so this is how the click knows it
    /// is the first one.
    private var takenBy: NSEvent?

    override func mouseDown(with event: NSEvent) {
        let first = takenBy.map { $0.timestamp == event.timestamp && $0.windowNumber == event.windowNumber } ?? false
        takenBy = nil
        // the click that takes the keyboard leaves the whole word selected, as taking
        // it does, and is not passed on to put a caret in it
        guard first, let editor = currentEditor() else { return super.mouseDown(with: event) }
        editor.selectAll(nil)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            takenBy = NSApp.currentEvent.flatMap { $0.type == .leftMouseDown ? $0 : nil }
            began()
        }
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
