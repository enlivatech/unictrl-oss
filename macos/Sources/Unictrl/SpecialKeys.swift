import AppKit
import CoreGraphics

/// Functions of the MX Keys special keys, performed on the computer under the pointer.
/// Values travel in the `action` message; the Windows receiver mirrors them.
enum KeyAction: UInt8 {
    case taskView = 1     // F3: Mission Control / Task View
    case apps = 2         // F4: Apps / Start menu
    case showDesktop = 3  // F5
    case screenshot = 4   // screenshot key: CleanShot X area capture / PixPin screenshot (both Ctrl+Shift+A)
    case lock = 5         // lock key

    /// MX Keys (B35B) control IDs taken over through HID++ 0x1B04.
    static let controls: [UInt16: KeyAction] = [0x00E0: .taskView, 0x00E1: .apps, 0x006E: .showDesktop]

    /// Performs the Mac side of the action.
    func performOnMac() {
        switch self {
        case .taskView:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case .apps:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.apps.launcher") {
                NSWorkspace.shared.open(url)
            }
        case .showDesktop:
            Self.post(keyCode: 103, flags: .maskSecondaryFn) // F11 = Show Desktop
        case .screenshot:
            Self.post(keyCode: 0, flags: [.maskControl, .maskShift]) // CleanShot X: Ctrl+Shift+A
        case .lock:
            Self.post(keyCode: 12, flags: [.maskControl, .maskCommand]) // Ctrl+Cmd+Q
        }
        Log.write("action_mac", "\(self)")
    }

    /// Posts a shortcut whose modifiers come from the event itself, so modifiers still physically
    /// held by the keyboard's own macro do not change it.
    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
