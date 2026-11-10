// Phraseo: the app. A document is one video and its captions: the transcript to correct,
// a style, a preview over the footage, and an Export that writes the caption track for
// Final Cut. A new document asks for its video at once.

import AppKit
import SwiftUI

@main
struct PhraseoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: { Document() }) { file in
            ContentView()
                .environmentObject(file.document)
                .frame(minWidth: 1100, minHeight: 700)
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
            MainActor.assumeIsolated { AppDelegate.openUntitledIfEmpty() }
        }
    }

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
            Button("Export Caption Track…") { doc?.export() }
                .keyboardShortcut("e")
                .disabled(doc?.transcript == nil || doc?.isBusy == true)
            Button("Save Style as Preset…") { doc?.savePreset() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(doc == nil)
        }
    }
}
