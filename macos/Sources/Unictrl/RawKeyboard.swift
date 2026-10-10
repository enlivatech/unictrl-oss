import Foundation
import IOKit.hid

/// Reads Logitech keyboard reports directly. Some MX Keys keys (calculator, screenshot, menu, lock)
/// send HID usages that macOS never turns into events, so the event tap cannot see them.
/// Needs Input Monitoring. The device is opened shared, so normal typing is unaffected.
final class RawKeyboard {
    /// usage page, usage, value (1 down / 0 up), host time in ns
    var onUsage: ((UInt32, UInt32, Int, UInt64) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private(set) var isRunning = false

    static var accessGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    static func requestAccess() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }

    func start() -> Bool {
        guard !isRunning else { return true }
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06], // keyboard
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0x0C, kIOHIDDeviceUsageKey: 0x01], // consumer
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let me = Unmanaged<RawKeyboard>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            // Skip array placeholders and pointer/button pages.
            guard usage != 0, usage != 0xFFFFFFFF, page != 0x01, page != 0x09 else { return }
            let ns = AbsoluteTimeToNs(IOHIDValueGetTimeStamp(value))
            me.onUsage?(page, usage, IOHIDValueGetIntegerValue(value), ns)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        isRunning = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        Log.write(isRunning ? "raw_keyboard_started" : "raw_keyboard_failed")
        return isRunning
    }
}

private func AbsoluteTimeToNs(_ ticks: UInt64) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return ticks * UInt64(info.numer) / UInt64(info.denom)
}
