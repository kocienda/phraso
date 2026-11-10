// Choosing a font the way Keynote does: a family menu with every family drawn in its
// own face, a style menu for the family's faces, and a size field. The style file keeps
// a PostScript name; the mapping to and from family and face happens here.

import AppKit
import SwiftUI

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

/// Family, style and size, bound to the style's PostScript name and size.
struct FontPicker: View {
    @Binding var font: String
    @Binding var size: CGFloat

    private var resolved: (family: String, face: String)? { Fonts.resolve(font) }

    /// The face menu's selection: the style's own name when the font manager lists it,
    /// else the member with the same face name ("Anton" is listed as "Anton-Regular").
    private var faceSelection: String {
        guard let r = resolved else { return font }
        let fs = Fonts.faces(of: r.family)
        return (fs.first { $0.ps == font } ?? fs.first { $0.face == r.face } ?? fs.first)?.ps ?? font
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pane.rowGap) {
            FamilyMenu(family: Binding(
                get: { resolved?.family ?? font },
                set: { fam in
                    if let ps = Fonts.member(of: fam, like: resolved?.face ?? "Regular") {
                        font = ps
                        Fonts.noteUsed(fam)
                    }
                }), missing: resolved == nil ? font : nil)
                .frame(width: Pane.content, height: Pane.control)
            HStack(spacing: 8) {
                FacePopUp(faces: resolved.map { Fonts.faces(of: $0.family) } ?? [(font, "Not installed")],
                          selection: Binding(get: { faceSelection }, set: { font = $0 }))
                    .disabled(resolved == nil)
                    .frame(height: Pane.control)
                ValueField(value: $size, in: 8...400, width: 55, suffix: "pt")
            }
            .frame(width: Pane.content)
        }
    }
}

/// The face pop-up for one family, full width like Keynote's.
struct FacePopUp: NSViewRepresentable {
    var faces: [(ps: String, face: String)]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.target = context.coordinator
        pop.action = #selector(Coordinator.pick(_:))
        pop.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return pop
    }

    func updateNSView(_ pop: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if pop.itemArray.map({ $0.representedObject as? String }) != faces.map({ Optional($0.ps) }) {
            pop.removeAllItems()
            for f in faces {
                let it = NSMenuItem(title: f.face, action: nil, keyEquivalent: "")
                it.representedObject = f.ps
                pop.menu?.addItem(it)
            }
        }
        if let i = faces.firstIndex(where: { $0.ps == selection }) { pop.selectItem(at: i) }
    }

    final class Coordinator: NSObject {
        var parent: FacePopUp
        init(_ p: FacePopUp) { parent = p }
        @objc func pick(_ pop: NSPopUpButton) {
            if let ps = pop.selectedItem?.representedObject as? String { parent.selection = ps }
        }
    }
}

/// The family pop-up: each family in its own face, the recently used ones first.
struct FamilyMenu: NSViewRepresentable {
    @Binding var family: String
    /// A PostScript name no installed font answers to; shown as the current item.
    var missing: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.target = context.coordinator
        pop.action = #selector(Coordinator.pick(_:))
        pop.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.rebuild(pop, recents: Fonts.recents)
        return pop
    }

    func updateNSView(_ pop: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let recents = Fonts.recents
        if recents != context.coordinator.recents { context.coordinator.rebuild(pop, recents: recents) }
        if let m = missing {
            if pop.item(withTitle: m) == nil {
                let item = NSMenuItem(title: m, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: m, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 13)])
                item.representedObject = m
                pop.menu?.insertItem(item, at: 0)
            }
            pop.selectItem(withTitle: m)
        } else if let i = pop.itemArray.firstIndex(where: { ($0.representedObject as? String) == family && !$0.isSeparatorItem }) {
            pop.selectItem(at: i)
        }
        // the button names the family in the system font, as Keynote's does; only the
        // menu draws each family in its own face
        if let cell = pop.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: missing ?? family, action: nil, keyEquivalent: "")
        }
    }

    final class Coordinator: NSObject {
        var parent: FamilyMenu
        var recents: [String] = []
        init(_ p: FamilyMenu) { parent = p }

        func rebuild(_ pop: NSPopUpButton, recents: [String]) {
            self.recents = recents
            let menu = NSMenu()
            menu.autoenablesItems = false
            for fam in recents { menu.addItem(item(fam)) }
            if !recents.isEmpty { menu.addItem(.separator()) }
            for fam in Fonts.families { menu.addItem(item(fam)) }
            pop.menu = menu
        }

        private func item(_ fam: String) -> NSMenuItem {
            let it = NSMenuItem(title: fam, action: nil, keyEquivalent: "")
            let f = (Fonts.member(of: fam, like: "Regular")).flatMap { NSFont(name: $0, size: 15) } ?? NSFont.menuFont(ofSize: 15)
            it.attributedTitle = NSAttributedString(string: fam, attributes: [.font: f])
            it.representedObject = fam
            return it
        }

        @objc func pick(_ pop: NSPopUpButton) {
            if let fam = pop.selectedItem?.representedObject as? String, Fonts.families.contains(fam) { parent.family = fam }
        }
    }
}
