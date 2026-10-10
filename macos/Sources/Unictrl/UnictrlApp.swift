import SwiftUI

@main
struct UnictrlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared

    /// Stacked-screens glyph; a template image, so macOS tints it for light and dark menu bars.
    private static let menuBarIcon: NSImage? = {
        let image = Bundle.main.image(forResource: "UnictrlMenubarTemplate")
        image?.isTemplate = true
        return image
    }()

    var body: some Scene {
        // Write back only real changes: SwiftUI sets this binding on every update, and each write to a
        // @Published property triggers another update (a busy loop that froze the main thread).
        MenuBarExtra(isInserted: Binding(get: { controller.showMenuBarIcon },
                                         set: { if $0 != controller.showMenuBarIcon { controller.showMenuBarIcon = $0 } })) {
            MenuPanel(controller: controller)
        } label: {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "cursorarrow.motionlines")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opening Unictrl again (Spotlight, Launchpad, Finder) or clicking its Dock icon shows Settings, so it
/// can be reached with either icon hidden.
/// SwiftUI does not pass the reopen event to an adaptor delegate, so it is taken straight from the
/// Apple Event manager.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(reopen(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEReopenApplication))
        MainActor.assumeIsolated { AppController.shared.applyDockIcon() }
        Log.write("app_delegate_ready")
    }

    @objc private func reopen(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        Log.write("reopen")
        MainActor.assumeIsolated { AppController.shared.showSettings() }
    }
}
