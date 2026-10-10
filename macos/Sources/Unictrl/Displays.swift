import AppKit
import CoreGraphics

/// A display in global (top-left origin) coordinates, with its physical scale from EDID.
struct DisplayGeometry {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let pointsPerMm: Double

    static func all() -> [DisplayGeometry] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let size = CGDisplayScreenSize(id)
            // ~127 points per inch is typical for Retina "looks like" resolutions.
            let ppm = size.width > 1 ? bounds.width / size.width : 5.0
            return DisplayGeometry(id: id, bounds: bounds, pointsPerMm: ppm)
        }
    }

    static var main: DisplayGeometry? { all().first { $0.id == CGMainDisplayID() } }
}

/// Hides the pointer while it is on the other computer. A background app may only hide the
/// cursor after opting in through the (private) SetsCursorInBackground connection property.
enum CursorVisibility {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    /// CGDisplayHideCursor calls not yet balanced by a show; `show` undoes them all. Guarded by `lock`:
    /// the tap thread and the cursor parker both hide.
    private static var hideCount = 0
    private static let lock = NSLock()

    /// macOS freezes local mouse input for 0.25 s after CGWarpMouseCursorPosition, which is felt as a
    /// hitch when the pointer comes back from Windows. Deprecated but still honoured; Deskflow does the same.
    static func disableWarpSuppression() {
        typealias SetInterval = @convention(c) (Double) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGSetLocalEventsSuppressionInterval") else { return }
        _ = unsafeBitCast(symbol, to: SetInterval.self)(0)
    }

    static func enableBackgroundHiding() {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else {
            Log.write("cursor_background_hide_unavailable")
            return
        }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSymbol, to: SetProperty.self)(connection, connection,
                                                          "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// Whether the window server is showing the cursor now (CGCursorIsVisible: unavailable to Swift,
    /// still exported). Nil if it is gone.
    private static let isVisibleFunction: (@convention(c) () -> Int32)? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    static func isVisible() -> Bool? {
        isVisibleFunction.map { $0() != 0 }
    }

    /// Hides the cursor; `again` hides it once more even if already hidden (something else may have
    /// shown it).
    static func hide(again: Bool = false) {
        lock.withLock {
            guard hideCount == 0 || again else { return }
            hideCount += 1
            CGDisplayHideCursor(CGMainDisplayID())
        }
    }

    static func show() {
        lock.withLock {
            while hideCount > 0 {
                hideCount -= 1
                CGDisplayShowCursor(CGMainDisplayID())
            }
        }
    }
}
