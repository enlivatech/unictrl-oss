import Foundation
import IOKit.pwr_mgt

/// Holds system sleep for a moment so the keyboard and mouse can be sent to a PC first
/// (IORegisterForSystemPower: sleep waits until each registered client allows it).
final class PowerMonitor {
    /// Runs before sleep; call the completion when done (sleep proceeds after at most ~25 s regardless).
    var willSleep: (@escaping () -> Void) -> Void = { $0() }
    var didPowerOn: () -> Void = {}

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    // IOKit message constants (iokit_common_msg), which Swift does not import.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            Log.write("power_monitor_failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            var allowed = false
            let allow = { [weak self] in
                guard let self, !allowed else { return }
                allowed = true
                IOAllowPowerChange(rootPort, token)
            }
            willSleep(allow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: allow) // never hold sleep for long
        case Self.systemHasPoweredOn:
            didPowerOn()
        default:
            break
        }
    }
}
