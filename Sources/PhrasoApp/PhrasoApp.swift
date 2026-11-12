// Phraso: the app. A document is one video and its captions: the transcript to correct,
// a style, a preview over the footage, and an Export that writes the caption track for
// Final Cut. A new document asks for its video at once.

import AppKit

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The application keeps its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    func applicationWillFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = MainMenu.make()
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishRestoringWindowsNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.restoring = false }
        }
    }

    /// True while the system brings back the windows of the last session. A window's
    /// own `restoreState(with:)` is no sign of this: a new window is sent it too.
    static var restoring = true

    /// Launching with nothing to restore makes a new document, which then asks for its video.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { !hasVisibleWindows }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
    }
}

/// The menu bar, built in code: the application menu, File, Edit, View, Playback, Window
/// and Help.
/// Every item acts through the responder chain, so the front document answers File's.
enum MainMenu {
    @MainActor static func make() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu()))
        bar.addItem(submenu(fileMenu()))
        bar.addItem(submenu(editMenu()))
        bar.addItem(submenu(viewMenu()))
        bar.addItem(submenu(playbackMenu()))
        let window = windowMenu()
        bar.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        bar.addItem(submenu(help))
        NSApp.helpMenu = help
        return bar
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu(title: "Phraso")
        m.addItem(item("About Phraso", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        m.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        m.addItem(submenu(services))
        NSApp.servicesMenu = services
        m.addItem(.separator())
        m.addItem(item("Hide Phraso", #selector(NSApplication.hide(_:)), "h"))
        m.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        m.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item("Quit Phraso", #selector(NSApplication.terminate(_:)), "q"))
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu(title: "File")
        m.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        m.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        // Open Recent is not built here: AppKit puts its own in after Open… for a
        // document-based app, and one made here would show as a second
        m.addItem(item("Choose Video…", #selector(Document.chooseVideo(_:)), "o", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        m.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        m.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:))))
        m.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        m.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        m.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        m.addItem(item("Browse All Versions…", #selector(NSDocument.browseVersions(_:))))
        m.addItem(.separator())
        m.addItem(item("Export…", #selector(Document.exportMovie(_:)), "e"))
        m.addItem(item("Save Style as Preset…", #selector(Document.saveStylePreset(_:)), "s", [.command, .shift]))
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu(title: "Edit")
        m.addItem(item("Undo", Selector(("undo:")), "z"))
        m.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        m.addItem(.separator())
        m.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        m.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        m.addItem(item("Delete", #selector(NSText.delete(_:))))
        m.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        m.addItem(.separator())
        // the word being typed in, or else the word under the playhead; its title says
        // which way it goes
        m.addItem(item("Add Card Break", #selector(DocumentWindowController.toggleCardBreak(_:)), "r"))
        return m
    }

    /// AppKit adds Enter Full Screen here.
    private static func viewMenu() -> NSMenu {
        let m = NSMenu(title: "View")
        m.addItem(item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]))
        return m
    }

    /// The transport, on the keys every player has. The items turn themselves off while a
    /// field has the keyboard, which leaves the keys to it.
    private static func playbackMenu() -> NSMenu {
        let m = NSMenu(title: "Playback")
        m.addItem(item("Play", #selector(Document.togglePlayback(_:)), " ", []))
        m.addItem(.separator())
        m.addItem(item("Back One Frame", #selector(Document.stepBackward(_:)), key(NSLeftArrowFunctionKey), []))
        m.addItem(item("Forward One Frame", #selector(Document.stepForward(_:)), key(NSRightArrowFunctionKey), []))
        m.addItem(.separator())
        m.addItem(item("Go to Start", #selector(Document.goToStart(_:)), key(NSHomeFunctionKey), []))
        m.addItem(item("Go to End", #selector(Document.goToEnd(_:)), key(NSEndFunctionKey), []))
        return m
    }

    private static func key(_ functionKey: Int) -> String {
        String(Character(UnicodeScalar(UInt16(functionKey))!))
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu(title: "Window")
        m.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        m.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return m
    }

    private static func helpMenu() -> NSMenu {
        let m = NSMenu(title: "Help")
        m.addItem(item("Phraso Help", #selector(NSApplication.showHelp(_:)), "?"))
        return m
    }
}
