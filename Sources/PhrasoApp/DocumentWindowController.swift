// A document's window: the views over the document, the toolbar beside the title, and
// the alert for anything that went wrong.

import AppKit
import Combine

final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    static let windowSize = NSSize(width: 1180, height: 780)
    /// Where the next new window's top left goes.
    private static var cascade = NSPoint.zero

    private let doc: Document
    private let film = FilmButton()
    private var exportItem: NSToolbarItem?
    private var bag: Set<AnyCancellable> = []

    init(document doc: Document) {
        self.doc = doc
        let w = DocumentWindow(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: true)
        w.animationBehavior = .none
        w.contentView = ContentView(doc: doc)
        w.contentMinSize = NSSize(width: 940, height: 600)
        super.init(window: w)
        film.doc = doc
        let toolbar = NSToolbar(identifier: "Document")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        w.toolbarStyle = .unified
        shouldCascadeWindows = false
        w.willShow = { [weak w] restored in
            // a window the system restores keeps the frame it was saved with
            if let w, !restored { Self.place(w) }
        }
        w.didShow = { [weak self, weak w] in
            // up with no word field holding the keyboard, so a new window does not start
            // typing into the transcript
            w?.makeFirstResponder(nil)
            self?.doc.windowDidShow()
        }
        watch()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Return with no field or control holding the keyboard goes to the first word. A key
    /// a field or a control has taken never gets this far, and one it passes up is left
    /// alone here too.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if event.keyCode == 36 || event.keyCode == 76, mods.isEmpty, let w = window, w.attachedSheet == nil,
           !(w.firstResponder is NSText), !(w.firstResponder is NSControl),
           (w.contentView as? ContentView)?.transcript.focusFirstWord() == true {
            return
        }
        super.keyDown(with: event)
    }

    /// Edit ▸ Add Card Break, ⌘R: ends the card after the word being typed in,
    /// or after the word under the playhead when no word has the keyboard, or takes the
    /// break off again.
    @objc func toggleCardBreak(_ sender: Any?) {
        (window?.contentView as? ContentView)?.transcript.toggleBreakOnTarget()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleCardBreak(_:)) else { return true }
        let state = window?.attachedSheet == nil ? (window?.contentView as? ContentView)?.transcript.breakState() : nil
        item.title = state == true ? "Remove Card Break" : "Add Card Break"
        return state != nil
    }

    /// The classic cascade: the first window at the top left of the screen, each next one
    /// a title bar down and across, starting over when the next would run off the screen.
    private static func place(_ w: DocumentWindow) {
        guard let screen = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = NSSize(width: min(windowSize.width, screen.width), height: min(windowSize.height, screen.height))
        var top = cascade
        if top == .zero || top.x + size.width > screen.maxX || top.y - size.height < screen.minY {
            top = NSPoint(x: screen.minX, y: screen.maxY)
        }
        w.placed = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        w.setFrame(w.placed!, display: false)
        cascade = w.cascadeTopLeft(from: top)
    }

    private func watch() {
        doc.$lastExport.receive(on: DispatchQueue.main).sink { [weak self] export in
            self?.film.toolTip = export.map {
                "Drag onto the Final Cut timeline to add \($0.movie.lastPathComponent). Click to choose another video (⇧⌘O)."
            } ?? "Choose the video or sound file to caption (⇧⌘O). After an Export, drag from here to put the caption movie on the Final Cut timeline."
        }.store(in: &bag)
        doc.$transcript.combineLatest(doc.$isBusy).receive(on: DispatchQueue.main).sink { [weak self] t, busy in
            self?.exportItem?.isEnabled = t != nil && !busy
        }.store(in: &bag)
        doc.$error.receive(on: DispatchQueue.main).sink { [weak self] e in
            if let e { self?.alert(e) }
        }.store(in: &bag)
    }

    private func alert(_ message: String) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Phraso"
        a.informativeText = message
        a.beginSheetModal(for: w) { [weak self] _ in self?.doc.error = nil }
    }

    // MARK: toolbar

    private static let filmID = NSToolbarItem.Identifier("film")
    private static let exportID = NSToolbarItem.Identifier("export")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.filmID, .flexibleSpace, Self.exportID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.filmID:
            // the icon beside the name, like a document's proxy icon
            item.label = "Choose Video"
            item.view = film
            item.isNavigational = true
        case Self.exportID:
            item.label = "Export"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
            item.action = #selector(Document.exportMovie(_:))
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = doc.transcript != nil && !doc.isBusy
            exportItem = item
        default:
            return nil
        }
        return item
    }
}

/// The film icon in the title bar: a click chooses the video, and after an Export a drag
/// takes the caption movie out, onto the Final Cut timeline.
final class FilmButton: NSButton, NSDraggingSource {
    weak var doc: Document?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "film", accessibilityDescription: "Choose Video")
        bezelStyle = .toolbar
        action = #selector(Document.chooseVideo(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        guard let movie = doc?.lastExport?.movie, let w = window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        while let next = w.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { sendAction(action, to: target) }
                return
            }
            let p = next.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) > 3 {
                let item = NSDraggingItem(pasteboardWriter: movie as NSURL)
                item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: movie.path))
                beginDraggingSession(with: [item], event: event, source: self)
                return
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// A document window that says when it first goes on screen. Neither the document's
/// `showWindows` nor the controller's `showWindow` is called for every window (the
/// untitled document made at launch comes up without either), but every window is
/// ordered in through here.
final class DocumentWindow: NSWindow {
    /// Before the window is first on screen, with whether the system is restoring it.
    var willShow: (Bool) -> Void = { _ in }
    /// On the turn after it is first on screen.
    var didShow: () -> Void = {}
    private var shown = false
    /// Made while the system brings back the last session's windows, so restored.
    private let restored = AppDelegate.restoring
    /// The frame it was placed at before going on screen, which it is held to: ordering
    /// in lays the toolbar out, and that grows the window by its height.
    var placed: NSRect?

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        let first = !shown && place != .out
        if first {
            shown = true
            willShow(restored)
        }
        super.order(place, relativeTo: otherWin)
        if first, let p = placed, frame != p { setFrame(p, display: true) }
        if first { DispatchQueue.main.async { self.didShow() } }
    }
}
