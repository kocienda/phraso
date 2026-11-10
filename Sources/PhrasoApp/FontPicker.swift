// Choosing a font the way Keynote does: a family menu with every family drawn in its
// own face, a style menu for the family's faces, and a size field. The style file keeps
// a PostScript name; the mapping to and from family and face happens here.

import AppKit

enum Fonts {
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    /// The faces of a family as (PostScript name, face name), in the font manager's order.
    static func faces(of family: String) -> [(ps: String, face: String)] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { m in
            guard let ps = m[0] as? String, let face = m[1] as? String else { return nil }
            return (ps, face)
        }
    }

    /// Family and face of a PostScript name, if the font is installed.
    static func resolve(_ ps: String) -> (family: String, face: String)? {
        guard let f = NSFont(name: ps, size: 12), let fam = f.familyName else { return nil }
        let face = faces(of: fam).first { $0.ps == ps }?.face
            ?? (f.fontDescriptor.object(forKey: .face) as? String) ?? "Regular"
        return (fam, face)
    }

    /// The face of `family` nearest `face`: the same name, else Regular, else the first.
    static func member(of family: String, like face: String) -> String? {
        let fs = faces(of: family)
        return (fs.first { $0.face == face } ?? fs.first { $0.face == "Regular" } ?? fs.first)?.ps
    }

    private static let recentsKey = "RecentFontFamilies"
    static var recents: [String] {
        get { (UserDefaults.standard.stringArray(forKey: recentsKey) ?? []).filter { families.contains($0) } }
        set { UserDefaults.standard.set(Array(newValue.prefix(6)), forKey: recentsKey) }
    }
    static func noteUsed(_ family: String) {
        recents = [family] + recents.filter { $0 != family }
    }
}

/// Family, style and size, reading and writing the style's PostScript name and size.
final class FontPicker: NSView, Refreshing {
    private let get: () -> (font: String, size: CGFloat)
    private let setFont: (String) -> Void
    private let family = FamilyMenu()
    private let face = FacePopUp()
    private let size: ValueField
    private var font = ""

    init(get: @escaping () -> (font: String, size: CGFloat), setFont: @escaping (String) -> Void, size: ValueField) {
        self.get = get
        self.setFont = setFont
        self.size = size
        super.init(frame: .zero)
        family.picked = { [weak self] fam in self?.pickFamily(fam) }
        face.picked = { [weak self] ps in self?.setFont(ps) }
        for v in [family, face, size] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            family.topAnchor.constraint(equalTo: topAnchor),
            family.leadingAnchor.constraint(equalTo: leadingAnchor),
            family.trailingAnchor.constraint(equalTo: trailingAnchor),
            family.heightAnchor.constraint(equalToConstant: Pane.control),
            face.topAnchor.constraint(equalTo: family.bottomAnchor, constant: Pane.rowGap),
            face.leadingAnchor.constraint(equalTo: leadingAnchor),
            face.heightAnchor.constraint(equalToConstant: Pane.control),
            face.bottomAnchor.constraint(equalTo: bottomAnchor),
            size.centerYAnchor.constraint(equalTo: face.centerYAnchor),
            size.leadingAnchor.constraint(equalTo: face.trailingAnchor, constant: 8),
            size.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        sized(self, Pane.content, nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var resolved: (family: String, face: String)? { Fonts.resolve(font) }

    private func pickFamily(_ fam: String) {
        if let ps = Fonts.member(of: fam, like: resolved?.face ?? "Regular") {
            setFont(ps)
            Fonts.noteUsed(fam)
        }
    }

    func refresh() {
        size.refresh()
        let now = get().font
        guard now != font || family.recents != Fonts.recents else { return }
        font = now
        let r = resolved
        family.show(family: r?.family ?? font, missing: r == nil ? font : nil)
        // the face menu's selection: the style's own name when the font manager lists it,
        // else the member with the same face name ("Anton" is listed as "Anton-Regular")
        let faces = r.map { Fonts.faces(of: $0.family) } ?? [(font, "Not installed")]
        let selection = r.map { r in (faces.first { $0.ps == font } ?? faces.first { $0.face == r.face } ?? faces.first)?.ps ?? font } ?? font
        face.show(faces: faces, selection: selection)
        face.isEnabled = r != nil
    }
}

/// The face pop-up for one family, full width like Keynote's.
final class FacePopUp: NSPopUpButton {
    var picked: (String) -> Void = { _ in }

    init() {
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(pick(_:))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(faces: [(ps: String, face: String)], selection: String) {
        if itemArray.map({ $0.representedObject as? String }) != faces.map({ Optional($0.ps) }) {
            removeAllItems()
            for f in faces {
                let it = NSMenuItem(title: f.face, action: nil, keyEquivalent: "")
                it.representedObject = f.ps
                menu?.addItem(it)
            }
        }
        if let i = faces.firstIndex(where: { $0.ps == selection }) { selectItem(at: i) }
    }

    @objc private func pick(_ sender: Any?) {
        if let ps = selectedItem?.representedObject as? String { picked(ps) }
    }
}

/// The family pop-up: each family in its own face, the recently used ones first.
final class FamilyMenu: NSPopUpButton {
    var picked: (String) -> Void = { _ in }
    private(set) var recents: [String] = []

    init() {
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(pick(_:))
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        rebuild(recents: Fonts.recents)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `family`, or `missing`, a PostScript name no installed font answers to, as
    /// the current item.
    func show(family: String, missing: String?) {
        let recents = Fonts.recents
        if recents != self.recents { rebuild(recents: recents) }
        if let m = missing {
            if item(withTitle: m) == nil {
                let item = NSMenuItem(title: m, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: m, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 13)])
                item.representedObject = m
                menu?.insertItem(item, at: 0)
            }
            selectItem(withTitle: m)
        } else if let i = itemArray.firstIndex(where: { ($0.representedObject as? String) == family && !$0.isSeparatorItem }) {
            selectItem(at: i)
        }
        // the button names the family in the system font, as Keynote's does; only the
        // menu draws each family in its own face
        if let cell = cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: missing ?? family, action: nil, keyEquivalent: "")
        }
    }

    private func rebuild(recents: [String]) {
        self.recents = recents
        let menu = NSMenu()
        menu.autoenablesItems = false
        for fam in recents { menu.addItem(item(fam)) }
        if !recents.isEmpty { menu.addItem(.separator()) }
        for fam in Fonts.families { menu.addItem(item(fam)) }
        self.menu = menu
    }

    private func item(_ fam: String) -> NSMenuItem {
        let it = NSMenuItem(title: fam, action: nil, keyEquivalent: "")
        let f = (Fonts.member(of: fam, like: "Regular")).flatMap { NSFont(name: $0, size: 15) } ?? NSFont.menuFont(ofSize: 15)
        it.attributedTitle = NSAttributedString(string: fam, attributes: [.font: f])
        it.representedObject = fam
        return it
    }

    @objc private func pick(_ sender: Any?) {
        if let fam = selectedItem?.representedObject as? String, Fonts.families.contains(fam) { picked(fam) }
    }
}
