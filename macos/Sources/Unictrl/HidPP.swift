import Foundation
import IOKit.hid

/// Minimal HID++ 2.0 client for a Logitech keyboard connected over Bluetooth, used to take over its
/// special keys (feature 0x1B04 "Reprogrammable keys and mouse buttons", as Logi Options+ does).
/// With a key diverted, the keyboard reports its control ID instead of a stand-in shortcut, so F4 is
/// no longer confused with F12 and keys that otherwise send nothing (calculator, menu) work.
/// Diversion is volatile: the keyboard forgets it on reconnect, and Unictrl reapplies it.
final class HidPP {
    struct Control {
        let cid: UInt16
        let tid: UInt16
        let flags: UInt8
        var divertable: Bool { flags & 0x20 != 0 }
    }

    /// Diverted control pressed (true) or released (false).
    var onControl: ((UInt16, Bool) -> Void)?

    private static let longReport: UInt8 = 0x11
    /// 0xFF for a device connected directly (Bluetooth); 1-6 for its slot on a receiver (Bolt).
    private var deviceIndex: UInt8 = 0xFF
    /// Through a receiver: the device to look for among its slots (by name), else nil.
    private var receiverDeviceName: String?
    private var receiverMissLogged = false
    private static let softwareID: UInt8 = 0x0B

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)
    private var pending: [(feature: UInt8, function: UInt8, handler: ([UInt8]?) -> Void)] = []
    private var featureIndex: UInt8?
    /// Other HID++ features by ID, looked up on demand (0x1814 ChangeHost, 0x1815 HostsInfo).
    private var featureIndexes: [UInt16: UInt8] = [:]
    /// Called when the device connects, once it answers HID++, and when it disconnects.
    var onAttach: (() -> Void)?
    var onReady: (() -> Void)?
    var onDetach: (() -> Void)?
    private(set) var productName = "?"
    /// The device was found and answered HID++ (through a receiver: its slot is known).
    var isReady: Bool { device != nil && featureIndex != nil }
    private var pressed: Set<UInt16> = []
    private(set) var controls: [Control] = []
    private var wanted: [UInt16] = []
    /// The minute-by-minute reapply logs only the first failure in a row for each key.
    private var reapplyFailing: Set<UInt16> = []
    /// Diagnostics: log every raw report except the keyboard report (ID 1), which carries typing.
    var logReportsUntil = Date.distantPast

    /// Starts watching for the keyboard; `divert` lists the control IDs to take over whenever it connects.
    func start(productID: Int, divert: [UInt16]) {
        wanted = divert
        let match: [String: Any] = [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: productID,
                                    kIOHIDDeviceUsagePageKey: 0xFF43, kIOHIDDeviceUsageKey: 0x0202]
        open(match)
    }

    /// Watches for a Logitech receiver (Bolt 0xC548, Unifying 0xC52B) and uses the paired device whose
    /// name contains `deviceName`, through its slot.
    func startReceiver(deviceName: String) {
        receiverDeviceName = deviceName
        let matches: [[String: Any]] = [0xC548, 0xC52B].map {
            [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: $0, kIOHIDDeviceUsagePageKey: 0xFF00, kIOHIDDeviceUsageKey: 0x0002]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        openManager()
    }

    private func open(_ match: [String: Any]) {
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        openManager()
    }

    private func openManager() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HidPP>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HidPP>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Diagnostics: take over `cids` for `seconds` so their presses are logged, then hand them back.
    func divertTemporarily(_ cids: [UInt16], seconds: TimeInterval) {
        for cid in cids { setReporting(cid, divert: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            for cid in cids where !wanted.contains(cid) { setReporting(cid, divert: false) }
        }
    }

    /// Hands every diverted key back to the keyboard (call before quitting).
    func restore() {
        for cid in wanted { setReporting(cid, divert: false) }
    }

    // MARK: Device lifecycle

    private func attach(_ newDevice: IOHIDDevice) {
        guard device == nil else { return }
        device = newDevice
        pending.removeAll()
        IOHIDDeviceRegisterInputReportCallback(newDevice, &reportBuffer, reportBuffer.count, { context, _, _, _, _, report, length in
            guard let context else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<HidPP>.fromOpaque(context).takeUnretainedValue().received(bytes)
        }, Unmanaged.passUnretained(self).toOpaque())
        productName = IOHIDDeviceGetProperty(newDevice, kIOHIDProductKey as CFString) as? String ?? "?"
        Log.write("hidpp_attached", "product=\(productName)")
        onAttach?()
        if let wantedName = receiverDeviceName {
            findSlot(1, named: wantedName, on: newDevice)
        } else {
            findReprogKeys(attempt: 0, on: newDevice)
        }
    }

    /// Asks each receiver slot for its device name (feature 0x0005) until one matches.
    private func findSlot(_ slot: UInt8, named wantedName: String, on target: IOHIDDevice) {
        guard device == target else { return }
        guard slot <= 6 else {
            // Not paired yet, or asleep / on another channel: a receiver cannot name a device that is
            // not connected. Look again shortly.
            if !receiverMissLogged { Log.write("hidpp_receiver_no_device", wantedName) }
            receiverMissLogged = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.findSlot(1, named: wantedName, on: target)
            }
            return
        }
        deviceIndex = slot
        featureIndexes = [:]
        readName { [weak self] name in
            guard let self, device == target else { return }
            if name != nil || !receiverMissLogged { Log.write("hidpp_receiver_slot", "slot=\(slot) name=\(name ?? "-")") }
            if let name, name.localizedCaseInsensitiveContains(wantedName) {
                receiverMissLogged = false
                productName = name
                findReprogKeys(attempt: 0, on: target)
            } else {
                findSlot(slot + 1, named: wantedName, on: target)
            }
        }
    }

    /// The device's marketing name (feature 0x0005: fn 0 length, fn 1 the bytes from an offset).
    private func readName(_ done: @escaping (String?) -> Void) {
        withFeature(0x0005) { [weak self] index in
            guard let self, let index else { done(nil); return }
            call(feature: index, function: 0, params: []) { [weak self] reply in
                guard let self, let length = reply?.first.map(Int.init), length > 0 else { done(nil); return }
                var bytes: [UInt8] = []
                func chunk() {
                    guard bytes.count < length else { done(String(decoding: bytes.prefix(length), as: UTF8.self)); return }
                    call(feature: index, function: 1, params: [UInt8(bytes.count)]) { part in
                        guard let part, !part.isEmpty else { done(nil); return }
                        bytes += part.prefix(length - bytes.count)
                        chunk()
                    }
                }
                chunk()
            }
        }
    }

    /// Looks up 0x1B04 through the root feature, then lists the keyboard's controls. A keyboard that
    /// has just woken over Bluetooth may not answer yet, so this retries for about a minute.
    private func findReprogKeys(attempt: Int, on target: IOHIDDevice) {
        guard device == target else { return }
        call(feature: 0, function: 0, params: [0x1B, 0x04]) { [weak self] reply in
            guard let self, device == target else { return }
            guard let reply, reply[0] != 0 else {
                let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
                guard attempt < delays.count else {
                    Log.write("hidpp_no_reprog_keys", "attempts=\(attempt + 1)")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
                    self?.findReprogKeys(attempt: attempt + 1, on: target)
                }
                return
            }
            if attempt > 0 { Log.write("hidpp_reprog_keys_found", "attempt=\(attempt + 1)") }
            featureIndex = reply[0]
            if wanted.isEmpty { onReady?() } else { readControls() }
        }
    }

    /// Diversion can be lost without the keyboard disconnecting (it sleeps, or another host took it
    /// for a moment); setting it again is harmless, so this runs every minute and after the Mac wakes.
    func reapply() {
        guard featureIndex != nil else { return }
        for cid in wanted where controls.contains(where: { $0.cid == cid && $0.divertable }) {
            setReporting(cid, divert: true, quiet: true)
        }
    }

    private func detach(_ gone: IOHIDDevice) {
        guard gone == device else { return }
        device = nil
        featureIndex = nil
        featureIndexes = [:]
        pending.removeAll()
        for cid in pressed { onControl?(cid, false) }
        pressed.removeAll()
        Log.write("hidpp_detached", productName)
        onDetach?()
    }

    private func readControls() {
        guard let feature = featureIndex else { return }
        call(feature: feature, function: 0, params: []) { [weak self] reply in
            guard let self, let count = reply?.first else { return }
            controls = []
            readControl(0, of: Int(count))
        }
    }

    private func readControl(_ index: Int, of count: Int) {
        guard let feature = featureIndex else { return }
        guard index < count else {
            Log.write("hidpp_controls", controls.map {
                String(format: "cid=0x%04X tid=0x%04X%@", $0.cid, $0.tid, $0.divertable ? " divertable" : "")
            }.joined(separator: " | "))
            for cid in wanted where controls.contains(where: { $0.cid == cid && $0.divertable }) {
                setReporting(cid, divert: true)
            }
            onReady?()
            return
        }
        call(feature: feature, function: 1, params: [UInt8(index)]) { [weak self] reply in
            guard let self else { return }
            if let r = reply, r.count >= 5 {
                controls.append(Control(cid: UInt16(r[0]) << 8 | UInt16(r[1]),
                                        tid: UInt16(r[2]) << 8 | UInt16(r[3]), flags: r[4]))
            }
            readControl(index + 1, of: count)
        }
    }

    private func setReporting(_ cid: UInt16, divert: Bool, quiet: Bool = false) {
        guard let feature = featureIndex else { return }
        // flags: bit0 divert, bit1 "divert flag is valid"
        call(feature: feature, function: 3, params: [UInt8(cid >> 8), UInt8(cid & 0xFF), divert ? 0x03 : 0x02]) { [weak self] reply in
            guard let self else { return }
            if quiet {
                guard reply == nil else { reapplyFailing.remove(cid); return }
                guard reapplyFailing.insert(cid).inserted else { return }
            }
            Log.write("hidpp_divert", String(format: "cid=0x%04X on=%d ok=%d", cid, divert ? 1 : 0, reply == nil ? 0 : 1))
        }
    }

    // MARK: Easy-Switch (0x1814 ChangeHost, 0x1815 HostsInfo)

    private func withFeature(_ id: UInt16, _ body: @escaping (UInt8?) -> Void) {
        if let index = featureIndexes[id] { body(index); return }
        call(feature: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)]) { [weak self] reply in
            guard let self, let reply, reply[0] != 0 else { body(nil); return }
            featureIndexes[id] = reply[0]
            body(reply[0])
        }
    }

    /// The number of Easy-Switch channels and the one in use (0-based).
    func hostInfo(_ done: @escaping ((count: Int, current: Int)?) -> Void) {
        withFeature(0x1814) { [weak self] index in
            guard let self, let index else { done(nil); return }
            call(feature: index, function: 0, params: []) { reply in
                guard let reply, reply.count >= 2 else { done(nil); return }
                done((Int(reply[0]), Int(reply[1])))
            }
        }
    }

    /// The Bluetooth name of the computer paired on each channel, where the device remembers one
    /// (0x1815: getHostInfo gives the name length, getHostFriendlyName returns it 14 bytes at a time).
    func hostNames(count: Int, _ done: @escaping ([Int: String]) -> Void) {
        withFeature(0x1815) { [weak self] index in
            guard let self, let index else { done([:]); return }
            var names: [Int: String] = [:]
            func next(_ host: Int) {
                guard host < count else { done(names); return }
                call(feature: index, function: 1, params: [UInt8(host)]) { [weak self] info in
                    guard let self, let info, info.count >= 6 else { next(host + 1); return }
                    Log.write("hidpp_host_info", "\(productName) host=\(host) " + info.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
                    let length = Int(info[4])
                    var bytes: [UInt8] = []
                    func chunk(_ offset: Int) {
                        guard offset < length else {
                            names[host] = String(decoding: bytes.prefix(length), as: UTF8.self)
                            next(host + 1)
                            return
                        }
                        call(feature: index, function: 3, params: [UInt8(host), UInt8(offset)]) { part in
                            guard let part, part.count > 2 else { next(host + 1); return }
                            bytes += part[2...]
                            chunk(offset + part.count - 2)
                        }
                    }
                    chunk(0)
                }
            }
            next(0)
        }
    }

    /// Sends the device to another Easy-Switch channel (0-based). It disconnects from this computer
    /// at once, usually without replying.
    func changeHost(to host: Int) {
        withFeature(0x1814) { [weak self] index in
            guard let self else { return }
            guard let index else { Log.write("hidpp_change_host_unsupported", productName); return }
            Log.write("hidpp_change_host", "\(productName) to=\(host)")
            call(feature: index, function: 1, params: [UInt8(host)]) { _ in }
        }
    }

    // MARK: Transport

    private func call(feature: UInt8, function: UInt8, params: [UInt8], handler: @escaping ([UInt8]?) -> Void) {
        guard let device else { handler(nil); return }
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = Self.longReport
        frame[1] = deviceIndex
        frame[2] = feature
        frame[3] = function << 4 | Self.softwareID
        for (i, byte) in params.prefix(16).enumerated() { frame[4 + i] = byte }
        pending.append((feature, function, handler))
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.longReport), frame, frame.count)
        if result != kIOReturnSuccess {
            pending.removeLast()
            handler(nil)
            return
        }
        // A reply normally arrives within milliseconds; give up after a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let i = pending.firstIndex(where: { $0.feature == feature && $0.function == function }) else { return }
            pending.remove(at: i).handler(nil)
        }
    }

    private func received(_ raw: [UInt8]) {
        if Date() < logReportsUntil, raw.first != 0x01 {
            Log.write("raw_report", raw.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        // IOKit may or may not include the report ID byte.
        var bytes = raw
        if bytes.first != Self.longReport && bytes.first != 0x10 { bytes.insert(Self.longReport, at: 0) }
        guard bytes.count >= 5 else { return }
        // A receiver reports for every slot; keep this device's.
        guard bytes[1] == deviceIndex else { return }
        let feature = bytes[2]
        let function = bytes[3] >> 4
        let swid = bytes[3] & 0x0F
        let params = Array(bytes[4...])
        if feature == 0xFF || feature == 0x8F { // HID++ 2.0 / 1.0 error: [.., feature, function|swid, code]
            if let i = pending.firstIndex(where: { $0.feature == bytes[3] }) { pending.remove(at: i).handler(nil) }
            return
        }
        if swid == Self.softwareID, let i = pending.firstIndex(where: { $0.feature == feature && $0.function == function }) {
            pending.remove(at: i).handler(params)
            return
        }
        // Notification: diverted buttons event lists up to four control IDs currently held.
        if feature == featureIndex, function == 0, swid == 0 {
            var now: Set<UInt16> = []
            for i in stride(from: 0, to: min(8, params.count - 1), by: 2) {
                let cid = UInt16(params[i]) << 8 | UInt16(params[i + 1])
                if cid != 0 { now.insert(cid) }
            }
            for cid in now.subtracting(pressed) { onControl?(cid, true) }
            for cid in pressed.subtracting(now) { onControl?(cid, false) }
            pressed = now
        }
    }
}
