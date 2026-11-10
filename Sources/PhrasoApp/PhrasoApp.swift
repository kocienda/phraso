// Phraso: the app. A document is one video and its captions: the transcript to correct,
// a style, a preview over the footage, and an Export that writes the caption track for
// Final Cut. A new document asks for its video at once.

import AppKit
import SwiftUI

@main
struct PhrasoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: { Document() }) { file in
            ContentView()
                .environmentObject(file.document)
                .frame(minWidth: 940, minHeight: 600)
        }
        .commands { DocumentCommands() }
    }
}

/// Launching with nothing to restore makes a new document straight away (which then
/// asks for its video) rather than showing SwiftUI's default Open panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ note: Notification) {
        // SwiftUI does not forward applicationShouldOpenUntitledFile, so once window
        // restoration has had its turn, make the document here if nothing came back.
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishRestoringWindowsNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.finishedRestoring = true; AppDelegate.openUntitledIfEmpty() }
        }
        TitleGate.install()
    }

    /// True once the system has brought back whatever windows it was going to.
    @MainActor static var finishedRestoring = false

    @MainActor static func openUntitledIfEmpty() {
        let documentWindows = NSApp.windows.filter { !($0 is NSPanel) && $0.isVisible }
        guard NSDocumentController.shared.documents.isEmpty, documentWindows.isEmpty else { return }
        DispatchQueue.main.async {
            guard NSDocumentController.shared.documents.isEmpty else { return }
            NSApp.windows.compactMap { $0 as? NSOpenPanel }.forEach { $0.cancel(nil) }
            NSDocumentController.shared.newDocument(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { !hasVisibleWindows }
}

/// Keeps the title bar's rename popover to the document's name and its chevron. The
/// system hangs the press that opens it on a container as wide as the empty bar beside
/// the name, so a click anywhere up there renames; this turns away presses that land
/// off the name, which leaves them to drag the window as a title bar should.
final class TitleGate: NSObject, NSGestureRecognizerDelegate {
    @MainActor static let shared = TitleGate()

    /// The toolbar builds its title view when it likes, so look for it on each click.
    @MainActor static func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let frame = event.window?.contentView?.superview { shared.gate(frame) }
            return event
        }
    }

    @MainActor private func gate(_ view: NSView) {
        if view.className == "NSToolbarPrimaryTitleContainerView" {
            for g in view.gestureRecognizers where g.delegate == nil { g.delegate = self }
            return
        }
        view.subviews.forEach(gate)
    }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let container = g.view else { return true }
        let name = container.subviews.filter { !$0.isHidden }.reduce(NSRect.null) { $0.union($1.frame) }
        return name.isNull || name.contains(container.convert(event.locationInWindow, from: nil))
    }
}

/// File-menu items that act on the front document.
struct DocumentCommands: Commands {
    @FocusedObject private var doc: Document?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Choose Video…") { doc?.askingForVideo = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(doc == nil)
        }
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export…") { doc?.export() }
                .keyboardShortcut("e")
                .disabled(doc?.transcript == nil || doc?.isBusy == true)
            Button("Save Style as Preset…") { doc?.savePreset() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(doc == nil)
        }
    }
}
