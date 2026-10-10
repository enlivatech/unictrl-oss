import AppKit
import SwiftUI

/// The one-page Settings window. A plain window rather than SwiftUI's Settings scene, which only
/// opens from a view.
@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible ?? false }

    func show(controller: AppController) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            hosting.sizingOptions = .minSize // the content sets the smallest size; the user sets the rest
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Unictrl Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 771, height: 776)) // default size, chosen by hand
            window.center()
            window.setFrameAutosaveName("UnictrlSettings") // reopens at the size and place it was left
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
