import AppKit

/// While the pointer is on a PC, covers the Mac screen it left with an almost invisible Unictrl window.
/// The window server will not let a background app hide the cursor over areas the Dock owns, and the
/// Dock owns the desktop picture: crossing over a bare desktop left the arrow stuck on the Mac edge.
/// Over a window of our own the hide is honoured. 1 % opacity, because a fully clear window is treated
/// as not there. Main thread only.
@MainActor final class CursorShield {
    static let shared = CursorShield()
    private var window: NSPanel?

    func show(on displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        let panel = window ?? makeWindow()
        window = panel
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        // The cursor now sits over our window: hide again so a stuck arrow is cleared.
        CursorVisibility.hide(again: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none // not in screenshots or recordings
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}
