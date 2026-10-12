import AppKit
import CoreGraphics

/// Owns the HID-level event tap. Locally it only watches for the pointer crossing an outer edge
/// toward a PC; while the pointer is on a PC it swallows hardware input and forwards it there.
///
/// Everything here runs on its own high-priority thread (`TapThread`), so a busy main thread cannot
/// delay input or get the tap disabled. Public methods may be called from any thread and hop over;
/// the main thread sees the state through `published` / `onStateChange`.
final class InputCapture {
    enum Mode { case local, remote }

    struct State {
        var mode = Mode.local
        /// The PC the pointer is on while remote, and the edge of it the pointer came in through.
        var remote: RemoteTarget?
        var entryEdge = Side.left
    }

    // Tap-thread state.
    private var mode: Mode = .local
    private var remote: RemoteTarget?
    private var entryEdge: Side = .left
    /// The PC next to the Mac on each side, if the pointer may cross to it now (set by the main thread).
    private var targets: [Side: [RemoteTarget]] = [:]

    /// The state as last published to the main thread; read it only there.
    private(set) var published = State()
    /// Called on the main thread after the state changes.
    var onStateChange: (State) -> Void = { _ in }
    /// Sends to a peer; called on the tap thread (and the scroll queue), so it must be thread-safe.
    var send: (_ peer: String, MessageWriter) -> Void = { _, _ in }

    private let thread = TapThread()

    /// Moves the call to the tap thread. Returns true if it did (the caller then returns at once).
    private func elsewhere(_ body: @escaping () -> Void) -> Bool {
        guard Thread.current !== thread else { return false }
        thread.perform(body)
        return true
    }

    private func publish() {
        let state = State(mode: mode, remote: remote, entryEdge: entryEdge)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            published = state
            onStateChange(state)
        }
    }

    /// Which PC the pointer may cross to on each side of the Mac; the main thread keeps this fresh.
    func setTargets(_ targets: [Side: [RemoteTarget]]) {
        if elsewhere({ self.setTargets(targets) }) { return }
        self.targets = targets
    }
    /// The side of the Mac the pointer left through; it comes back the same way.
    private var macSide: Side = .right

    private func send(_ message: MessageWriter) {
        if let remote { send(remote.id, message) }
    }

    /// Runs a special key's function on whichever computer has the pointer.
    func perform(_ action: KeyAction) {
        if elsewhere({ self.perform(action) }) { return }
        if mode == .remote {
            var message = MessageWriter(.action)
            message.u8(action.rawValue)
            send(message)
            Log.write("action_remote", "\(action)")
        } else {
            DispatchQueue.main.async { action.performOnMac() }
        }
    }

    private var settings: UnictrlSettings
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var edge: DisplayGeometry?
    private var suppressEdgeUntil = Date.distantPast
    /// Where the hidden Mac cursor is held while the pointer is on a PC: the middle of the screen it
    /// left, far from edges, hot corners and the way to an iPad.
    private var parkPoint: CGPoint?
    private let parker = CursorParker()
    /// A put-back is queued or running; don't queue another.
    private var putBackPending = false
    private var displays: [DisplayGeometry] = []
    private var displaysReadAt = Date.distantPast
    private var scrollFactor = 1.0
    private let localScroll = ScrollSmoother()
    private let remoteScroll = ScrollSmoother()
    private var loggedScrollSample = false
    private var syntheticPassed = 0
    private var movesLogged = 0
    private var identifyKeysUntil = Date.distantPast
    /// Device time (ms) at which each modifier keycode went down, to spot keyboard macros.
    private var modifierDownAt: [UInt16: Double] = [:]
    private var swallowKeyUp: Set<UInt16> = []
    private var deviceGaps: [Double] = []
    private var callbackGaps: [Double] = []
    private var lastDeviceTime: UInt64 = 0
    private var lastCallbackTime: UInt64 = 0
    private var gapWindowStart: UInt64 = 0
    // kCGEventUnacceleratedPointerMovementX/Y: device counts before macOS pointer acceleration.
    private static let unacceleratedX = CGEventField(rawValue: 170)!
    private static let unacceleratedY = CGEventField(rawValue: 171)!

    init(settings: UnictrlSettings) {
        self.settings = settings
        localScroll.emit = { dx, dy in ScrollPoster.post(dx: dx, dy: dy) }
        remoteScroll.emit = { [weak self] dx, dy in self?.sendWheel(dy: dy, dx: dx) }
    }

    private func sendWheel(dy: Double, dx: Double) {
        var message = MessageWriter(.wheel)
        message.f32(Float(dy))
        message.f32(Float(dx))
        send(message)
    }

    /// A physical mouse wheel sends discrete notches; trackpads and Magic Mouse send continuous scrolls.
    private static func isMouseWheel(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
    }

    /// Local mouse-wheel handling (reverse, smooth). Returns nil to swallow the original event.
    private func handleLocalScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard event.getIntegerValueField(.eventSourceUserData) != ScrollPoster.tag,
              Self.isMouseWheel(event) else { return pass }
        let sign = settings.reverseMouseWheel ? -1.0 : 1.0
        if !loggedScrollSample {
            loggedScrollSample = true
            Log.diagnostic("scroll_sample", String(format: "point=%.1f fixed=%.2f line=%lld",
                                              event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                                              event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                                              event.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        }
        if settings.smoothScrolling {
            // Glide the same pixel distance macOS would have jumped (its acceleration included).
            var dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            var dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if dy == 0 && dx == 0 { // no pixel deltas: 1 line ≈ 10 px
                dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 10
                dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * 10
            }
            localScroll.add(dx: dx * sign * settings.scrollScale, dy: dy * sign * settings.scrollScale)
            return nil
        }
        if sign < 0 {
            for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2] {
                event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
            }
            for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                                        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
                event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
            }
        }
        return pass
    }

    func update(settings: UnictrlSettings) {
        if elsewhere({ self.update(settings: settings) }) { return }
        self.settings = settings
        if mode == .remote { scrollFactor = remoteScrollFactor() } // a slider moved while on a PC
    }

    /// Lines sent to a PC per line of wheel: macOS's own scroll speed (as Deskflow does, 1 line x
    /// (1 + scaling), keeping the fraction) times the PC scroll speed. Deltas at the HID tap already
    /// include natural scrolling; only a later rewriter (e.g. Mos) needs invertScroll.
    private func remoteScrollFactor() -> Double {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let speed = 1 + ((global?["com.apple.scrollwheel.scaling"] as? NSNumber)?.doubleValue ?? 0)
        return speed * settings.pcScrollScale * ((settings.invertScroll ?? false) ? -1 : 1)
    }

    var isInstalled: Bool { tap != nil }

    // MARK: Tap lifecycle

    @discardableResult
    func install() -> Bool {
        if Thread.current !== thread { return thread.performAndWait { self.install() } }
        guard tap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        mask |= CGEventMask(1) << 14 // NSSystemDefined: media keys
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<InputCapture>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    func uninstall() {
        if Thread.current !== thread { return thread.performAndWait { self.uninstall() } }
        if mode == .remote { returnLocal(yMm: nil, reason: "uninstall") }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Other apps (Typeless) put active HID taps at the head of the chain and swallow the keys they
    /// use. Re-inserting ours keeps the dictation keys going to the computer under the pointer.
    func ensureFirstInChain() {
        if elsewhere({ self.ensureFirstInChain() }) { return }
        guard mode == .local, tap != nil,
              let first = firstActiveHIDTap(), first.pid != getpid() else { return }
        Log.write("tap_reorder", "ahead=\(first.name)")
        uninstall()
        install()
    }

    private func firstActiveHIDTap() -> (pid: pid_t, name: String)? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return nil }
        guard let first = list.prefix(Int(count)).first(where: {
            $0.tapPoint == .cghidEventTap && $0.options == .defaultTap && $0.enabled
        }) else { return nil }
        let name = NSRunningApplication(processIdentifier: first.tappingProcess)?.localizedName ?? "pid \(first.tappingProcess)"
        return (first.tappingProcess, name)
    }

    /// Diagnostics: for a short time, log which special keys arrive and what they send. Letters,
    /// digits, punctuation and plain modifiers are never logged.
    func identifyKeys(for seconds: TimeInterval) {
        if elsewhere({ self.identifyKeys(for: seconds) }) { return }
        identifyKeysUntil = Date().addingTimeInterval(seconds)
        Log.write("identify_keys_started", "seconds=\(Int(seconds))")
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Microseconds of uptime, wrapping: the PC compares arrival times with it to see delay spikes.
    private static func sendClock() -> UInt32 {
        UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1000)
    }

    private static func ms(_ event: CGEvent) -> Double {
        Double(event.timestamp) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    /// Raw HID usages from RawKeyboard, logged only while identifying keys.
    func rawUsage(page: UInt32, usage: UInt32, value: Int, ns: UInt64) {
        if elsewhere({ self.rawUsage(page: page, usage: usage, value: value, ns: ns) }) { return }
        guard Date() < identifyKeysUntil else { return }
        if page == 0x07 && (0x04...0x38).contains(usage) { return } // characters stay private
        Log.write("raw_usage", String(format: "page=0x%X usage=0x%X value=%d t=%.1f", page, usage, value, Double(ns) / 1_000_000))
    }

    private func logSpecialKey(_ type: CGEventType, _ event: CGEvent) {
        let flags = event.flags
        var mods = [String]()
        if flags.contains(.maskControl) { mods.append("ctrl") }
        if flags.contains(.maskAlternate) { mods.append("opt") }
        if flags.contains(.maskCommand) { mods.append("cmd") }
        if flags.contains(.maskShift) { mods.append("shift") }
        if flags.contains(.maskSecondaryFn) { mods.append("fn") }
        let fn = mods.isEmpty ? "" : " mods=" + mods.joined(separator: "+")
        switch type {
        case .keyDown where event.getIntegerValueField(.keyboardEventAutorepeat) == 0, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let usage = KeyMap.keyboard[code]
            if let usage, (0x04...0x38).contains(usage) { return } // characters stay private
            Log.write(type == .keyDown ? "key_down" : "key_up",
                      String(format: "keycode=%d t=%.1f", code, Self.ms(event)) + fn)
        case .flagsChanged:
            Log.write("modifier_change", String(format: "keycode=%d t=%.1f", event.getIntegerValueField(.keyboardEventKeycode), Self.ms(event)) + fn)
        default:
            if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {
                let keyType = (ns.data1 & 0xFFFF_0000) >> 16
                let down = (ns.data1 & 0xFF00) >> 8 == 0x0A
                if ns.subtype.rawValue != 7, ns.subtype.rawValue != 8 || down {
                    Log.write("system_key_seen", "subtype=\(ns.subtype.rawValue) keytype=\(keyType) data1=0x\(String(ns.data1, radix: 16))\(fn)")
                }
            }
        }
    }

    /// The MX Keys screenshot and lock keys emit shortcuts (Cmd+Shift+digit, Ctrl+Cmd+Q) with both
    /// modifiers pressed within a millisecond, which no hand does. Returns nil to continue normally,
    /// or .some(result) when the event was consumed here.
    private func handleKeyboardMacro(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>?? {
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return nil }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .flagsChanged:
            if let bit = KeyMap.modifierMask[code] {
                if event.flags.rawValue & bit != 0 { modifierDownAt[code] = Self.ms(event) } else { modifierDownAt[code] = nil }
            }
            return nil
        case .keyUp:
            if swallowKeyUp.remove(code) != nil { return .some(nil) }
            return nil
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
            func together(_ a: UInt16, _ b: UInt16) -> Bool {
                guard let ta = modifierDownAt[a], let tb = modifierDownAt[b] else { return false }
                return abs(ta - tb) < 3 && Self.ms(event) - max(ta, tb) < 60
            }
            let action: KeyAction?
            if [20, 21, 23].contains(code), together(0x37, 0x38) { // Cmd+Shift+3/4/5
                action = .screenshot
            } else if code == 12, together(0x37, 0x3B), mode == .remote { // Ctrl+Cmd+Q; the Mac locks natively
                action = .lock
            } else {
                action = nil
            }
            guard let action else { return nil }
            swallowKeyUp.insert(code)
            perform(action)
            return .some(nil)
        default:
            return nil
        }
    }

    // MARK: Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.write("tap_reenabled", "type=\(type.rawValue)")
            if mode == .remote { returnLocal(yMm: nil, reason: "tap_disabled") }
            return pass
        }

        if Date() < identifyKeysUntil { logSpecialKey(type, event) }
        if let result = handleKeyboardMacro(type, event) { return result }
        if mode == .local {
            if type == .scrollWheel { return handleLocalScroll(event) }
            guard type == .mouseMoved else { return pass }
            recordMoveGap(event)
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            guard Date() >= suppressEdgeUntil, NSEvent.pressedMouseButtons == 0 else { return pass }
            let horizontal: [Side] = dx == 0 ? [] : [dx < 0 ? .left : .right]
            let vertical: [Side] = dy == 0 ? [] : [dy < 0 ? .top : .bottom]
            for side in abs(dx) >= abs(dy) ? horizontal + vertical : vertical + horizontal {
                guard let display = edgeDisplay(at: event.location, side: side) else { continue }
                let along = side.horizontal ? (event.location.y - display.bounds.midY) / display.pointsPerMm
                                            : (event.location.x - display.bounds.midX) / display.pointsPerMm
                guard let target = targets[side]?.first(where: {
                    let center = side.horizontal ? $0.offsetMm : $0.xMm
                    let length = side.horizontal ? $0.heightMm : $0.widthMm
                    return along >= center - length / 2 && along < center + length / 2
                }) else { continue }
                crossingEventTime = event.timestamp
                enterRemote(target, side: side, from: display, at: event.location)
                return nil
            }
            return pass
        }

        // Remote: keystrokes other apps synthesise (Typeless or Uniclip pasting) belong to the Mac.
        // Pointer and wheel events are forwarded whatever their source: device utilities such as
        // Logi Options+ re-post the physical wheel as their own events.
        let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isKeyboard && event.getIntegerValueField(.eventSourceUnixProcessID) != 0 && !isAutorepeat {
            syntheticPassed += 1
            if syntheticPassed <= 5 {
                Log.write("synthetic_passed", "type=\(type.rawValue) pid=\(event.getIntegerValueField(.eventSourceUnixProcessID))")
            }
            return pass
        }
        // Forward first: nothing on the way may delay the move the PC is waiting for.
        let forwarded = forward(type, event)
        if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) {
            keepCursorParked(at: event.location)
        }
        return forwarded ? nil : pass
    }

    /// Returns false for events that should stay on the Mac.
    private func forward(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let rawX = event.getDoubleValueField(Self.unacceleratedX)
            let rawY = event.getDoubleValueField(Self.unacceleratedY)
            if movesLogged < 12 {
                movesLogged += 1
                Log.diagnostic("move_sample", String(format: "raw=%.2f,%.2f mac=%.2f,%.2f", rawX, rawY,
                                                event.getDoubleValueField(.mouseEventDeltaX),
                                                event.getDoubleValueField(.mouseEventDeltaY)))
            }
            recordMoveGap(event)
            if settings.pointerMode == "native" {
                var message = MessageWriter(.moveRaw)
                message.f32(Float(rawX * settings.pcPointerScale))
                message.f32(Float(rawY * settings.pcPointerScale))
                message.u32(Self.sendClock())
                send(message)
            } else {
                let ppm = edge?.pointsPerMm ?? 5
                var message = MessageWriter(.move)
                message.f32(Float(event.getDoubleValueField(.mouseEventDeltaX) / ppm * settings.pcPointerScale))
                message.f32(Float(event.getDoubleValueField(.mouseEventDeltaY) / ppm * settings.pcPointerScale))
                message.u32(Self.sendClock())
                send(message)
            }

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let button: Int64
            switch type {
            case .leftMouseDown, .leftMouseUp: button = 0
            case .rightMouseDown, .rightMouseUp: button = 1
            default: button = event.getIntegerValueField(.mouseEventButtonNumber)
            }
            guard (0...4).contains(button) else { return true }
            var message = MessageWriter(.button)
            message.u8(UInt8(button))
            message.u8([.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) ? 1 : 0)
            send(message)

        case .scrollWheel:
            // The PC scrolls the way this wheel scrolls on the Mac: a reversed mouse wheel is reversed
            // there too, trackpads keep their direction, and wheel notches glide when smoothing is on.
            let wheel = Self.isMouseWheel(event)
            let scale = scrollFactor * (wheel && settings.reverseMouseWheel ? -1 : 1)
            let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * scale
            let dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * scale
            if wheel && settings.smoothScrolling {
                remoteScroll.add(dx: dx, dy: dy)
            } else {
                sendWheel(dy: dy, dx: dx)
            }

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let usage = KeyMap.keyboard[code] else {
                Log.write("unmapped_key", "keycode=\(code)")
                return true
            }
            sendKey(page: 0x07, usage: usage, down: type == .keyDown)

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if code == KeyMap.capsLock {
                // macOS reports the lock state, and the keyboard light follows the Mac: send the state
                // so the PC matches it instead of toggling on its own.
                sendCapsLock(event.flags.contains(.maskAlphaShift))
            } else if let bit = KeyMap.modifierMask[code], let usage = KeyMap.keyboard[code] {
                sendKey(page: 0x07, usage: usage, down: event.flags.rawValue & bit != 0)
            }
            // fn stays in the keyboard; swallow it.

        default:
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return false
            }
            let keyType = (ns.data1 & 0xFFFF_0000) >> 16
            let down = (ns.data1 & 0xFF00) >> 8 == 0x0A
            if keyType == 4 { return true } // NX_KEYTYPE_CAPS_LOCK: Caps Lock travels as flagsChanged
            if let usage = KeyMap.media[keyType] {
                sendKey(page: 0x0C, usage: usage, down: down)
                if down { Log.write("media_remote", String(format: "type=%d usage=0x%02X", keyType, usage)) }
            } else if down {
                Log.write("unmapped_media_key", "type=\(keyType)")
            }
        }
        return true
    }

    /// About once a second while the mouse moves: how its events arrived. Called on the main thread.
    struct MouseWindow {
        /// The PC the pointer was on, nil on the Mac.
        var peer: String?
        var events: Int
        /// The mouse's radio link paused and its reports arrived in a burst.
        var stalls: Int
        /// Events that reached this tap 20 ms or more after the Mac received them from the mouse.
        var late: Int
    }
    var onMouseWindow: (MouseWindow) -> Void = { _ in }

    /// Diagnostics: gaps between mouse events by the device's own timestamp and by when this tap
    /// received them. Device gaps mean the radio link paused; callback-only gaps mean the tap was late.
    // Stall detection: after a gap of 30 ms or more, reports that piled up on the way (radio or
    // system) arrive together; a natural pause of the hand resumes at the normal pace.
    private var burstStart: UInt64 = 0
    private var burstEvents = 0
    private var stalls = 0
    private var pauses = 0
    private var late = 0
    private var inLate = false
    /// Times the Mac cursor had to be put back while remote, and the slowest put-back.
    private var refreezes = 0
    private var refreezeMaxMs = 0.0
    private var tapDelays: [Double] = []

    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private func recordMoveGap(_ event: CGEvent) {
        let now = DispatchTime.now().uptimeNanoseconds
        let device = Self.nanoseconds(event.timestamp)
        // From the Mac receiving the report to this tap: the system's share of the delay.
        let delayMs = now > device ? Double(now - device) / 1_000_000 : 0
        if delayMs < 1000 {
            tapDelays.append(delayMs)
            if delayMs >= 20, !inLate { late += 1; inLate = true } else if delayMs < 8 { inLate = false }
        }
        if burstStart != 0 {
            if now - burstStart <= 4_000_000 {
                burstEvents += 1
            } else {
                if burstEvents >= 2 { stalls += 1 } else { pauses += 1 }
                burstStart = 0
            }
        }
        if lastCallbackTime != 0, now - lastCallbackTime >= 30_000_000, now - lastCallbackTime < 1_000_000_000, burstStart == 0 {
            burstStart = now
            burstEvents = 0
        }
        if lastCallbackTime != 0, now - lastCallbackTime < 100_000_000 {
            callbackGaps.append(Double(now - lastCallbackTime) / 1_000_000)
            if device > lastDeviceTime { deviceGaps.append(Double(device - lastDeviceTime) / 1_000_000) }
        } else if gapWindowStart == 0 {
            gapWindowStart = now
        }
        lastCallbackTime = now
        lastDeviceTime = device
        guard gapWindowStart != 0, now - gapWindowStart >= 1_000_000_000 else { return }
        if callbackGaps.count >= 20, Log.diagnostics {
            func stats(_ values: [Double]) -> String {
                let sorted = values.sorted()
                guard !sorted.isEmpty else { return "-" }
                func p(_ q: Double) -> String { String(format: "%.1f", sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))]) }
                return "p50=\(p(0.5)) p90=\(p(0.9)) p99=\(p(0.99)) max=\(p(1))"
            }
            Log.write("mac_mouse", "mode=\(mode == .remote ? "remote" : "local") n=\(callbackGaps.count) stalls=\(stalls) pauses=\(pauses) late=\(late) device_gap_ms \(stats(deviceGaps)) tap_gap_ms \(stats(callbackGaps)) tap_delay_ms \(stats(tapDelays))" +
                      (mode == .remote ? String(format: " refreezes=%d refreeze_max_ms=%.1f", refreezes, refreezeMaxMs) : ""))
        }
        if mode == .remote, let peer = remote?.id {
            let window = MouseWindow(peer: peer, events: callbackGaps.count, stalls: stalls, late: late)
            DispatchQueue.main.async { [weak self] in self?.onMouseWindow(window) }
        }
        stalls = 0
        pauses = 0
        late = 0
        refreezes = 0
        refreezeMaxMs = 0
        tapDelays.removeAll(keepingCapacity: true)
        deviceGaps.removeAll(keepingCapacity: true)
        callbackGaps.removeAll(keepingCapacity: true)
        gapWindowStart = now
    }

    /// Caps Lock (usage 0x39) carries the Mac's lock state in `down`; the PC switches only if it differs.
    private func sendCapsLock(_ on: Bool) {
        sendKey(page: 0x07, usage: 0x39, down: on)
    }

    private func sendKey(page: UInt8, usage: UInt16, down: Bool) {
        var message = MessageWriter(.key)
        message.u8(page)
        message.u16(usage)
        message.u8(down ? 1 : 0)
        send(message)
    }

    // MARK: Edge crossing

    private func edgeDisplay(at point: CGPoint, side: Side) -> DisplayGeometry? {
        if Date().timeIntervalSince(displaysReadAt) > 2 {
            displays = DisplayGeometry.all()
            displaysReadAt = Date()
        }
        guard let display = displays.first(where: {
            point.y >= $0.bounds.minY && point.y < $0.bounds.maxY &&
                point.x >= $0.bounds.minX && point.x < $0.bounds.maxX
        }) else { return nil }
        let atEdge: Bool
        switch side {
        case .left: atEdge = point.x <= display.bounds.minX + 0.5
        case .right: atEdge = point.x >= display.bounds.maxX - 1.5
        case .top: atEdge = point.y <= display.bounds.minY + 0.5
        case .bottom: atEdge = point.y >= display.bounds.maxY - 1.5
        }
        guard atEdge else { return nil }
        let beyond: CGPoint
        switch side {
        case .left: beyond = CGPoint(x: display.bounds.minX - 1, y: point.y)
        case .right: beyond = CGPoint(x: display.bounds.maxX + 1, y: point.y)
        case .top: beyond = CGPoint(x: point.x, y: display.bounds.minY - 1)
        case .bottom: beyond = CGPoint(x: point.x, y: display.bounds.maxY + 1)
        }
        let hasNeighbor = displays.contains { $0.id != display.id && $0.bounds.contains(beyond) }
        return hasNeighbor ? nil : display
    }

    private func enterRemote(_ target: RemoteTarget, side: Side, from display: DisplayGeometry, at point: CGPoint) {
        edge = display
        macSide = side
        mode = .remote
        localScroll.stop()
        syntheticPassed = 0
        movesLogged = 0
        scrollFactor = remoteScrollFactor()
        let crossedAt = DispatchTime.now().uptimeNanoseconds
        let eventAgeMs = crossedAt > Self.nanoseconds(crossingEventTime) ? Double(crossedAt - Self.nanoseconds(crossingEventTime)) / 1_000_000 : 0
        // Hide first: the arrow should leave the Mac screen as early as possible (the freeze takes 1-3 ms).
        CursorVisibility.hide()
        let hideMs = Double(DispatchTime.now().uptimeNanoseconds - crossedAt) / 1_000_000
        let visibleAfterHide = CursorVisibility.isVisible() == true
        CGAssociateMouseAndMouseCursorPosition(0)
        let park = CGPoint(x: display.bounds.midX, y: display.bounds.midY)
        parkPoint = park
        putBackSamples = 0
        putBacksSinceEnter = 0
        putBack(to: park)
        let shieldDisplay = display.id
        DispatchQueue.main.async { CursorShield.shared.show(on: shieldDisplay) }
        let yMm = side.horizontal ? (point.y - display.bounds.midY) / display.pointsPerMm - target.offsetMm
                                 : (point.x - display.bounds.midX) / display.pointsPerMm - target.xMm
        sendEnter(to: target, yMm: yMm, edge: side.opposite, resume: false)
        Log.write("enter_remote", String(format: "id=%@ y_mm=%.1f ppm=%.3f event_age_ms=%.1f hide_ms=%.1f visible_after_hide=%d",
                                         String(target.id.prefix(8)), yMm, display.pointsPerMm, eventAgeMs, hideMs, visibleAfterHide ? 1 : 0))
        publish()
    }

    /// While the pointer is on a PC the Mac cursor must stay put and hidden. macOS often ignores the
    /// freeze for a background app, so the hidden cursor follows the hand: let it roam around the middle
    /// of the screen and put it back only when it has gone far, off this thread.
    private func keepCursorParked(at location: CGPoint) {
        guard let park = parkPoint, !putBackPending,
              hypot(location.x - park.x, location.y - park.y) > 150 else { return }
        putBack(to: park, seen: location)
    }

    /// Diagnostics: the first put-backs after each crossing, to see where the cursor really is.
    private var putBackSamples = 0
    /// macOS sometimes drops the hide made at the crossing: the first two put-backs after each crossing
    /// hide again whatever the 2 s limit says (repeated crossings within 2 s used to skip it).
    private var putBacksSinceEnter = 0
    /// Device timestamp of the event that crossed, to log how late the crossing was handled.
    private var crossingEventTime: UInt64 = 0

    private func putBack(to point: CGPoint, seen: CGPoint? = nil) {
        putBackPending = true
        refreezes += 1
        let sample = seen != nil && putBackSamples < 3
        if sample { putBackSamples += 1 }
        putBacksSinceEnter += 1
        parker.putBack(to: point, check: seen != nil, forceHide: putBacksSinceEnter <= 2) { [weak self] ms, after in
            if sample, let seen {
                Log.diagnostic("put_back_sample", String(format: "event=%.0f,%.0f park=%.0f,%.0f cursor_after=%.0f,%.0f ms=%.1f",
                                                    seen.x, seen.y, point.x, point.y, after.x, after.y, ms))
            }
            self?.thread.perform {
                self?.putBackPending = false
                self?.refreezeMaxMs = max(self?.refreezeMaxMs ?? 0, ms)
            }
        }
    }

    /// enter: f32 yMm, u8 edge (0 left, 1 right), u8 flags (bit0 resume, bit1 left edge open, bit2 right edge open).
    private func sendEnter(to target: RemoteTarget, yMm: Double, edge: Side, resume: Bool) {
        remote = target
        entryEdge = edge
        var message = MessageWriter(.enter)
        message.f32(Float(yMm))
        message.u8(edge.rawValue)
        message.u8((resume ? 1 : 0) | (target.openLeft ? 2 : 0) | (target.openRight ? 4 : 0) | (target.openTop ? 8 : 0) | (target.openBottom ? 16 : 0))
        send(message)
        publish()
        sendCapsLock(CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift))
    }

    /// The pointer left one PC toward another: carry on there. `yMm` is relative to the new PC's centre.
    func switchRemote(to target: RemoteTarget, yMm: Double, edge: Side) {
        if elsewhere({ self.switchRemote(to: target, yMm: yMm, edge: edge) }) { return }
        guard mode == .remote else { return }
        remoteScroll.stop()
        sendEnter(to: target, yMm: yMm, edge: edge, resume: false)
        Log.write("switch_remote", String(format: "id=%@ y_mm=%.1f", String(target.id.prefix(8)), yMm))
    }

    /// The PC's session was replaced, or its neighbours changed, while the pointer was on it:
    /// activate the new session where the pointer is and tell it which edges lead on.
    func resumeRemote(_ target: RemoteTarget) {
        if elsewhere({ self.resumeRemote(target) }) { return }
        guard mode == .remote, remote?.id == target.id else { return }
        sendEnter(to: target, yMm: 0, edge: entryEdge, resume: true)
        Log.write("resume_remote")
    }

    /// Brings the pointer back to the Mac. `yMm` is relative to the Mac screen's centre; `macEdge` is the
    /// Mac edge that faces the PC it comes from (default: the edge it left through, which differs if the
    /// screens were rearranged meanwhile).
    func returnLocal(yMm: Double?, reason: String, macEdge: Side? = nil) {
        if elsewhere({ self.returnLocal(yMm: yMm, reason: reason, macEdge: macEdge) }) { return }
        guard mode == .remote else { return }
        if let macEdge { macSide = macEdge }
        mode = .local
        remote = nil
        parkPoint = nil
        parker.stop() // waits for a put-back in flight, so it cannot land after the warp below
        putBackPending = false
        remoteScroll.stop()
        let display = edge ?? DisplayGeometry.main
        if let display {
            var x = display.bounds.midX, y = display.bounds.midY
            if macSide.horizontal {
                y += (yMm ?? 0) * display.pointsPerMm
                x = macSide == .left ? display.bounds.minX + 3 : display.bounds.maxX - 3
            } else {
                x += (yMm ?? 0) * display.pointsPerMm
                y = macSide == .top ? display.bounds.minY + 3 : display.bounds.maxY - 3
            }
            x = min(display.bounds.maxX - 2, max(display.bounds.minX + 1, x))
            y = min(display.bounds.maxY - 2, max(display.bounds.minY + 1, y))
            CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        }
        // Re-associating right after the warp avoids macOS's post-warp input freeze.
        CGAssociateMouseAndMouseCursorPosition(1)
        CursorVisibility.show()
        DispatchQueue.main.async { CursorShield.shared.hide() }
        suppressEdgeUntil = Date().addingTimeInterval(0.25)
        Log.write("return_local", "reason=\(reason)")
        publish()
    }
}

/// Puts the hidden Mac cursor back on its own thread: warping and hiding are calls into the window
/// server that take a few milliseconds, too long for the event tap.
private final class CursorParker {
    private let queue = DispatchQueue(label: "Unictrl cursor parker", qos: .userInteractive)
    private var lastHide = Date.distantPast
    private var lastEscapeLog = Date.distantPast
    private var enteredAt = DispatchTime.now()
    private var shownLoggedThisCrossing = false

    /// `done` gets the time taken and where the cursor is afterwards. `check`: the cursor should already
    /// be on `point` (not on the crossing itself, when it is still at the edge). `forceHide`: hide again
    /// now, just after a crossing.
    func putBack(to point: CGPoint, check: Bool, forceHide: Bool, done: @escaping (Double, CGPoint) -> Void) {
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            if !check {
                enteredAt = DispatchTime.now()
                shownLoggedThisCrossing = false
            }
            // Normally the frozen cursor sits on the park point. If it has moved, something undid the
            // freeze and the Mac cursor is following the hand next to the PC's: hide it again at once.
            let before = CGEvent(source: nil)?.location ?? point
            let drift = check ? hypot(before.x - point.x, before.y - point.y) : 0
            CGAssociateMouseAndMouseCursorPosition(0)
            CGWarpMouseCursorPosition(point)
            // Something may have shown it again; hiding stacks, so not on every put-back.
            if forceHide || drift > 12 || Date().timeIntervalSince(lastHide) > 2 {
                lastHide = Date()
                CursorVisibility.hide(again: true)
            }
            // Hidden is what the PC's user expects; if anything showed the cursor again, hide it now.
            if CursorVisibility.isVisible() == true {
                CursorVisibility.hide(again: true)
                lastHide = Date()
                if !shownLoggedThisCrossing {
                    shownLoggedThisCrossing = true
                    let afterMs = Double(DispatchTime.now().uptimeNanoseconds - enteredAt.uptimeNanoseconds) / 1_000_000
                    let hiddenNow = CursorVisibility.isVisible() == false
                    DispatchQueue.main.async {
                        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                        Log.write("cursor_shown_again", String(format: "after_ms=%.0f drift=%.0f hidden_now=%d front=%@",
                                                               afterMs, drift, hiddenNow ? 1 : 0, front))
                    }
                }
            }
            if drift > 12, Date().timeIntervalSince(lastEscapeLog) > 5 {
                lastEscapeLog = Date()
                DispatchQueue.main.async {
                    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                    Log.write("cursor_escaped", String(format: "drift=%.0f front=%@", drift, front))
                }
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            done(ms, CGEvent(source: nil)?.location ?? .zero)
        }
    }

    /// Returns once any put-back queued before it has run. Put-backs are queued from the tap thread
    /// only, so none can follow.
    func stop() {
        queue.sync {}
    }
}
