import AppKit
import ApplicationServices
import Combine
import Security
import ServiceManagement

/// App-lifetime owner of the server, the event tap and the menu state.
@MainActor final class AppController: ObservableObject {
    static let shared = AppController()

    /// A paired PC as the menu and settings show it.
    struct Device: Identifiable, Equatable {
        let id: String
        var name: String
        var online: Bool
        var latencyMs: Int?
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var arrangement = Arrangement()
    /// The PC the pointer is on, if any.
    @Published private(set) var remoteID: String?
    var isRemote: Bool { remoteID != nil }
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringGranted = RawKeyboard.accessGranted
    @Published var startAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard startAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            setLoginItem(startAtLogin)
        }
    }
    @Published var reverseMouseWheel: Bool {
        didSet { settings.reverseMouseWheel = reverseMouseWheel; applySettings() }
    }
    @Published var smoothScrolling: Bool {
        didSet { settings.smoothScrolling = smoothScrolling; applySettings() }
    }
    /// "native": each PC's own pointer speed; "physical": the Mac's, converted by millimetres.
    @Published var pointerMode: String {
        didSet { settings.pointerMode = pointerMode; applySettings() }
    }
    /// See UnictrlSettings.shareChannel; -1 in the picker stands for "any channel".
    @Published var shareChannel: Int {
        didSet {
            guard shareChannel != oldValue else { return }
            settings.shareChannel = shareChannel < 0 ? nil : shareChannel
            settings.save()
            applyShareChannel()
        }
    }
    @Published var readySound: Bool {
        didSet { settings.readySound = readySound; settings.save() }
    }
    @Published var readySoundName: String {
        didSet {
            guard readySoundName != oldValue else { return }
            settings.readySoundName = readySoundName
            settings.save()
            NSSound(named: readySoundName)?.play() // let the user hear the choice
        }
    }
    /// The system alert sounds, for the picker.
    let systemSounds: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    @Published var pcScrollScale: Double {
        didSet { settings.pcScrollScale = pcScrollScale; applySettings() }
    }
    @Published var pcPointerScale: Double {
        didSet { settings.pcPointerScale = pcPointerScale; applySettings() }
    }
    @Published var scrollScale: Double {
        didSet { settings.scrollScale = scrollScale; applySettings() }
    }
    /// The menu bar icon (the panel lives there) and the Dock icon. Both may be off: opening Unictrl
    /// again shows Settings.
    @Published var showMenuBarIcon: Bool {
        didSet {
            guard showMenuBarIcon != oldValue else { return }
            settings.showMenuBarIcon = showMenuBarIcon
            settings.save()
        }
    }
    @Published var showDockIcon: Bool {
        didSet {
            guard showDockIcon != oldValue else { return }
            settings.showDockIcon = showDockIcon
            settings.save()
            applyDockIcon()
        }
    }
    @Published var sleepHandoff: Bool {
        didSet { settings.sleepHandoff = sleepHandoff; settings.save(); objectWillChange.send() }
    }
    /// What happens to the keyboard and mouse when the Mac sleeps, for Settings.
    @Published private(set) var easySwitchNote = "Looking for the keyboard…"
    @Published var enabled: Bool {
        didSet {
            settings.enabled = enabled
            settings.save()
            if !enabled { capture.returnLocal(yMm: nil, reason: "disabled") }
            pushTargets()
            Log.write("enabled_changed", "\(enabled)")
        }
    }

    private var settings: UnictrlSettings
    private let server: PeerServer
    private let capture: InputCapture
    private let rawKeyboard = RawKeyboard()
    private let pairingWindow = PairingWindow()
    private let settingsWindow = SettingsWindow()
    private var discovery: DiscoveryResponder?
    private let hidpp = HidPP()
    /// The mouse, for Easy-Switch only.
    private let mouseHidpp = HidPP()
    /// The same mouse through a Logi Bolt receiver; whichever answers is used.
    private let boltMouse = HidPP()
    private var mouse: HidPP?
    private let power = PowerMonitor()
    /// Easy-Switch channels of each device: the one in use (this Mac) and the paired computers' names.
    private struct Hosts { var current: Int; var count: Int; var names: [Int: String] }
    private var keyboardHosts: Hosts?
    private var mouseHosts: Hosts?
    /// Devices sent to a PC when the Mac slept, and the Mac's own channels to bring them back to.
    private var away: (peer: String, keyboard: Int, mouse: Int?)?
    /// After a wake: keep asking the PC for the devices until the keyboard is back or this passes.
    private var reclaimUntil: Date?
    private var nextReclaim = Date.distantPast
    private var lastRemoteID: String?
    private var lastPong: [String: Date] = [:]
    private var latency: [String: Int] = [:]
    /// Live connection quality per PC, for Settings, the menu and the PCs.
    let quality = QualityMonitor()
    private var macLinkReadAt = Date.distantPast
    /// The checklist last sent to each PC; reports carry it only when it changed.
    private var sentTips: [String: [Tip]] = [:]
    /// While the pointer is on a PC, a dropped session gets a moment to be replaced (new pairing key,
    /// app restart) before the pointer is taken back.
    private var disconnectGrace: DispatchWorkItem?
    private var timers: [Timer] = []
    private var activity: NSObjectProtocol?

    private init() {
        var settings = UnictrlSettings.load()
        settings.migrate()
        settings.normalize()
        if UUID(uuidString: settings.deviceID) == nil {
            settings.deviceID = UUID().uuidString
        }
        settings.save()
        self.settings = settings
        enabled = settings.enabled
        reverseMouseWheel = settings.reverseMouseWheel
        smoothScrolling = settings.smoothScrolling
        sleepHandoff = settings.sleepHandoff
        showMenuBarIcon = settings.showMenuBarIcon
        showDockIcon = settings.showDockIcon
        pointerMode = settings.pointerMode
        scrollScale = settings.scrollScale
        pcPointerScale = settings.pcPointerScale
        pcScrollScale = settings.pcScrollScale
        shareChannel = settings.shareChannel ?? -1
        readySound = settings.readySound
        readySoundName = settings.readySoundName
        arrangement = settings.arrangement
        server = PeerServer(settings: settings)
        server.deviceID = UUID(uuidString: settings.deviceID)!
        server.displayName = { MainActor.assumeIsolated { AppController.shared.macName } }
        capture = InputCapture(settings: settings)
        wire()
        refreshDevices()
        start()
    }

    var statusLine: String {
        guard accessibilityGranted else { return "Needs Accessibility permission" }
        if !channelAllowsSharing {
            if let current = currentChannel, keyboardHere { return "Paused on Easy-Switch \(current + 1)" }
            return "Paused: keyboard not on this Mac"
        }
        if let remoteID, let device = devices.first(where: { $0.id == remoteID }) { return "Using \(device.name)" }
        let online = devices.filter(\.online)
        if devices.isEmpty { return "No PCs paired" }
        if online.isEmpty { return "Waiting for PCs…" }
        return online.count == 1 ? "Connected to \(online[0].name)" : "Connected to \(online.count) PCs"
    }

    /// This Mac's name as shown everywhere: the user's choice, else the computer name.
    var macName: String { settings.macAlias ?? macComputerName }
    var macComputerName: String { Host.current().localizedName ?? "Mac" }

    /// The name a screen shows ("mac" or a PC's ID).
    func name(of id: String) -> String {
        id == Arrangement.mac ? macName : settings.peers.first { $0.id == id }?.displayName ?? "PC"
    }

    /// The computer name a screen would show without a rename, for the rename field's placeholder.
    func defaultName(of id: String) -> String {
        id == Arrangement.mac ? macComputerName : settings.peers.first { $0.id == id }?.name ?? "PC"
    }

    /// Renames this Mac or a PC; an empty name goes back to the computer name. Every PC hears about it.
    func rename(_ id: String, to newName: String) {
        let trimmed = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let alias: String? = trimmed.isEmpty || trimmed == defaultName(of: id) ? nil : trimmed
        if id == Arrangement.mac {
            guard settings.macAlias != alias else { return }
            settings.macAlias = alias
        } else {
            guard let i = settings.peers.firstIndex(where: { $0.id == id }), settings.peers[i].alias != alias else { return }
            settings.peers[i].alias = alias
        }
        settings.save()
        Log.write("renamed", "id=\(id.prefix(8))")
        refreshDevices()
        broadcastArrangement()
        updateEasySwitchNote()
        objectWillChange.send()
    }

    /// Physical size of the Mac's main screen in mm.
    var macScreenMm: CGSize {
        guard let main = DisplayGeometry.main else { return CGSize(width: 302, height: 196) }
        return CGSize(width: main.bounds.width / main.pointsPerMm, height: main.bounds.height / main.pointsPerMm)
    }

    func screenSize(of id: String) -> CGSize {
        if id == Arrangement.mac { return macScreenMm }
        guard let peer = settings.peers.first(where: { $0.id == id }) else { return CGSize(width: 290, height: 193) }
        return CGSize(width: peer.widthMm, height: peer.heightMm)
    }

    /// Saves a new arrangement (from the Mac's settings or a PC) and tells every PC.
    func setArrangement(_ new: Arrangement) {
        var new = new
        new.normalize(peers: settings.peers.map(\.id))
        guard new != settings.arrangement else { return }
        guard Arrangement.connected(new.rectangles(sizes: screenSizes)) else { broadcastArrangement(); return }
        settings.arrangement = new
        settings.save()
        arrangement = new
        Log.write("arranged", new.order.map { $0 == Arrangement.mac ? "mac" : String($0.prefix(8)) }.joined(separator: ","))
        broadcastArrangement()
        refreshEdges()
        pushTargets()
    }

    /// Forgets a PC: its key, its place in the row and its connection.
    func removePeer(_ id: String) {
        if remoteID == id { capture.returnLocal(yMm: nil, reason: "removed") }
        settings.peers.removeAll { $0.id == id }
        settings.arrangement.remove(id)
        settings.save()
        arrangement = settings.arrangement
        server.disconnect(id)
        lastPong[id] = nil
        latency[id] = nil
        quality.forget(id)
        refreshDevices()
        broadcastArrangement()
        Log.write("peer_removed", "id=\(id.prefix(8))")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows a 6-digit code that a Windows PC enters to pair; valid for two minutes.
    func startPairing() {
        closePanel()
        let code = Pairing.newCode()
        server.pairingCode = code
        pairingWindow.onClose = { [weak self] in self?.server.pairingCode = nil }
        pairingWindow.show(code: code)
        Log.write("pairing_started")
    }

    /// A Dock icon makes Unictrl a regular app; without it Unictrl lives in the menu bar only.
    func applyDockIcon() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if !showDockIcon, settingsWindow.isVisible { NSApp.activate() } // keep an open Settings window in front
    }

    /// Opens the Settings window.
    func showSettings() {
        closePanel()
        settingsWindow.show(controller: self)
    }

    /// The menu bar panel stays open after a button in it is used; close it before opening a window.
    func closePanel() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("MenuBarExtra") {
            window.orderOut(nil)
        }
    }

    /// Every screen for the arrangement canvas, left to right.
    var tiles: [ScreenTile] {
        settings.arrangement.order.map { id in
            if id == Arrangement.mac { return ScreenTile(id: id, name: macName, sizeMm: macScreenMm, online: true) }
            let peer = settings.peers.first { $0.id == id }
            return ScreenTile(id: id, name: peer?.displayName ?? "PC", sizeMm: screenSize(of: id), online: server.isConnected(id))
        }
    }

    var port: UInt16 { settings.port }

    func requestInputMonitoring() {
        RawKeyboard.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Log.write("login_item", "on=\(on)")
        } catch {
            Log.write("login_item_failed", "\(error)")
        }
        let actual = SMAppService.mainApp.status == .enabled
        if startAtLogin != actual { startAtLogin = actual }
    }

    private func setDiagnostics(_ on: Bool) {
        settings.diagnostics = on
        settings.save()
        Log.diagnostics = on
        if on { MainThreadWatchdog.start() } else { MainThreadWatchdog.stop() }
        Log.write("diagnostics", on ? "on" : "off")
    }

    private func applySettings() {
        settings.save()
        capture.update(settings: settings)
    }

    func quit() {
        hidpp.restore()
        capture.uninstall()
        server.stop()
        NSApp.terminate(nil)
    }

    // MARK: Wiring

    private func wire() {
        server.keyFor = { [unowned self] id in
            settings.peers.first { $0.id == id }?.pairingKey
        }

        capture.send = { [unowned self] peer, message in server.send(message, to: peer) }
        capture.onMouseWindow = { [unowned self] window in
            guard let peer = window.peer else { return }
            quality.addMouseWindow(peer, events: window.events, stalls: window.stalls, late: window.late)
        }
        quality.pcName = { [unowned self] id in name(of: id) }
        capture.onStateChange = { [unowned self] state in
            remoteID = state.remote?.id
            if let remoteID { lastRemoteID = remoteID }
        }

        server.onConnected = { [unowned self] id, name in
            lastPong[id] = Date()
            quality.connected(id)
            if let i = settings.peers.firstIndex(where: { $0.id == id }), settings.peers[i].name != name {
                settings.peers[i].name = name
                settings.save()
            }
            dropStaleLegacyPeer(named: name, keeping: id)
            refreshDevices()
            broadcastArrangement() // every PC shows who is online
            refreshEdges()
            pushTargets()
            if let grace = disconnectGrace, capture.published.remote?.id == id {
                grace.cancel()
                disconnectGrace = nil
                if let target = target(id, requireFresh: false) { capture.resumeRemote(target) } // the new session carries on
            }
        }
        server.onDisconnected = { [unowned self] id, reason in
            latency[id] = nil
            sentTips[id] = nil
            refreshDevices()
            broadcastArrangement()
            pushTargets()
            if capture.published.remote?.id == id {
                disconnectGrace?.cancel()
                let grace = DispatchWorkItem { [weak self] in
                    self?.disconnectGrace = nil
                    self?.capture.returnLocal(yMm: nil, reason: "peer_\(reason)")
                }
                disconnectGrace = grace
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: grace)
            } else {
                refreshEdges()
            }
        }
        server.onBound = { [unowned self] id in
            // A PC paired before device IDs: from now on it is known by its ID.
            guard let i = settings.peers.firstIndex(where: { $0.id == "" }) else { return }
            if settings.peers.contains(where: { $0.id == id }) {
                settings.peers.remove(at: i)
                settings.arrangement.remove("")
            } else {
                settings.peers[i].id = id
                settings.arrangement.rename("", to: id)
            }
            settings.save()
            arrangement = settings.arrangement
            lastPong[""] = nil
            Log.write("peer_bound", "id=\(id.prefix(8))")
        }
        server.onMessage = { [unowned self] id, data in handle(data, from: id) }
        server.onPaired = { [unowned self] id, key in
            if let i = settings.peers.firstIndex(where: { $0.id == id }) {
                settings.peers[i].pairingKey = key
            } else {
                settings.peers.append(PeerConfig(id: id, name: "Windows PC", pairingKey: key))
                settings.arrangement.add(id)
            }
            settings.save()
            arrangement = settings.arrangement
            refreshDevices()
            pairingWindow.paired()
            // No disconnect: the PC opens a session with the new key, which replaces the old one.
        }
        rawKeyboard.onUsage = { [unowned self] page, usage, value, ns in
            capture.rawUsage(page: page, usage: usage, value: value, ns: ns)
        }
    }

    /// A PC that re-paired under its device ID leaves its old pre-ID entry behind; drop it.
    private func dropStaleLegacyPeer(named name: String, keeping id: String) {
        guard !id.isEmpty, let legacy = settings.peers.first(where: { $0.id == "" }), legacy.name == name else { return }
        settings.peers.removeAll { $0.id == "" }
        if settings.arrangement.order.contains(id) {
            settings.arrangement.remove("")
        } else {
            settings.arrangement.rename("", to: id)
        }
        settings.save()
        arrangement = settings.arrangement
        server.disconnect("")
    }

    /// Whether the pointer can go to a PC right now.
    private func isAvailable(_ id: String, requireFresh: Bool = true) -> Bool {
        server.isConnected(id) && (!requireFresh || Date().timeIntervalSince(lastPong[id] ?? .distantPast) < 1.5)
    }

    private func target(_ id: String, requireFresh: Bool = true) -> RemoteTarget? {
        guard id != Arrangement.mac, isAvailable(id, requireFresh: requireFresh) else { return nil }
        let row = settings.arrangement
        guard let rect = row.rectangles(sizes: screenSizes)[id] else { return nil }
        func open(_ side: Side) -> Bool {
            row.neighbors(of: id, on: side, sizes: screenSizes).contains {
                $0 == Arrangement.mac || isAvailable($0, requireFresh: false)
            }
        }
        return RemoteTarget(id: id, offsetMm: rect.midY, xMm: rect.midX, widthMm: rect.width, heightMm: rect.height,
                            openLeft: open(.left), openRight: open(.right), openTop: open(.top), openBottom: open(.bottom))
    }

    private var screenSizes: [String: CGSize] {
        Dictionary(uniqueKeysWithValues: settings.arrangement.order.map { ($0, screenSize(of: $0)) })
    }

    func placePeer(_ id: String, on side: Side) {
        let size = screenSize(of: id), mac = macScreenMm
        let point: CGPoint
        switch side {
        case .left: point = CGPoint(x: -(mac.width + size.width) / 2, y: 0)
        case .right: point = CGPoint(x: (mac.width + size.width) / 2, y: 0)
        case .top: point = CGPoint(x: 0, y: -(mac.height + size.height) / 2)
        case .bottom: point = CGPoint(x: 0, y: (mac.height + size.height) / 2)
        }
        setArrangement(settings.arrangement.placing(id, at: point, sizes: screenSizes))
    }

    /// Tells the PC under the pointer which of its edges lead on, after a PC came or went.
    private func refreshEdges() {
        guard disconnectGrace == nil, let current = capture.published.remote, let fresh = target(current.id, requireFresh: false),
              fresh.openLeft != current.openLeft || fresh.openRight != current.openRight ||
              fresh.openTop != current.openTop || fresh.openBottom != current.openBottom ||
              fresh.xMm != current.xMm || fresh.offsetMm != current.offsetMm else { return }
        capture.resumeRemote(fresh)
    }

    private func refreshDevices() {
        let list = settings.arrangement.order.compactMap { id -> Device? in
            guard let peer = settings.peers.first(where: { $0.id == id }) else { return nil }
            return Device(id: id, name: peer.displayName, online: server.isConnected(id), latencyMs: latency[id])
        }
        if list != devices { devices = list }
        updateEasySwitchNote()
    }

    private func arrangementMessage(for id: String) -> ArrangementMessage {
        let rects = settings.arrangement.rectangles(sizes: screenSizes)
        let screens = settings.arrangement.order.map { screen -> ArrangementMessage.Screen in
            let size = screenSize(of: screen)
            let name = name(of: screen)
            var info = ArrangementMessage.Screen(id: screen, name: name,
                widthMm: Double((size.width * 10).rounded() / 10), heightMm: Double((size.height * 10).rounded() / 10),
                offsetMm: settings.arrangement.offset(of: screen), online: screen == Arrangement.mac || server.isConnected(screen))
            if let rect = rects[screen] { info.xMm = Double(rect.midX); info.yMm = Double(rect.midY) }
            return info
        }
        return ArrangementMessage(you: id, screens: screens)
    }

    private func sendArrangement(to id: String) {
        guard server.isModern(id), let json = try? JSONEncoder().encode(arrangementMessage(for: id)) else { return }
        var message = MessageWriter(.arrangement)
        message.bytes(json)
        server.send(message, to: id)
    }

    private func broadcastArrangement() {
        for id in server.connectedPeers { sendArrangement(to: id) }
    }

    private func start() {
        if !settings.loginItemConfigured {
            // Start at login by default; the menu can turn it off.
            settings.loginItemConfigured = true
            settings.save()
            startAtLogin = true
        }
        CursorVisibility.enableBackgroundHiding()
        CursorVisibility.disableWarpSuppression()
        do { try server.start() } catch { Log.write("listen_failed", "\(error)") }
        discovery = DiscoveryResponder(deviceID: server.deviceID, port: settings.port)
        discovery?.name = { [unowned self] in MainActor.assumeIsolated { macName } }
        discovery?.start()
        installTapWhenAllowed()
        if !RawKeyboard.accessGranted { RawKeyboard.requestAccess() }
        startRawKeyboardWhenAllowed()

        // Common modes: pings must go on while a menu tracks or a window resizes, or the PCs time out.
        func every(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
            let timer = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { body() } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        every(0.5) { [weak self] in self?.heartbeat() }
        // While the pointer is on a PC, measure its round trip ten times a second.
        every(0.1) { [weak self] in self?.pingRemote() }
        every(1) { [weak self] in self?.updateQuality() }
        Log.diagnostics = settings.diagnostics
        if settings.diagnostics { MainThreadWatchdog.start() }
        every(3) { [weak self] in self?.capture.ensureFirstInChain() }
        every(60) { [weak self] in self?.hidpp.reapply() }
        // A menu bar app with no window is otherwise App Napped, which throttles those timers.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Forwarding input to PCs")
        power.willSleep = { [unowned self] done in MainActor.assumeIsolated { handleSleep(done) } }
        power.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            // The keyboard reconnects a few seconds after wake.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self?.hidpp.reapply() } }
        }
        // Diagnostics trigger from Terminal:
        // swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.enlivatech.unictrl.identifyKeys"), object: nil, deliverImmediately: true)'
        DistributedNotificationCenter.default().addObserver(forName: .init("com.enlivatech.unictrl.identifyKeys"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.capture.identifyKeys(for: 90)
                self?.hidpp.logReportsUntil = Date().addingTimeInterval(90)
            }
        }
        // Development: open windows from Terminal for screenshots (object: "settings", "pair"),
        // forget a test PC ("remove <id>"), ask PCs for their Easy-Switch channels ("hosts-test"), or
        // switch the icons ("dock-on", "dock-off", "menubar-on", "menubar-off").
        DistributedNotificationCenter.default().addObserver(forName: .init("com.enlivatech.unictrl.debug"),
                                                            object: nil, queue: .main) { [weak self] note in
            let command = note.object as? String
            MainActor.assumeIsolated {
                if command == "settings" { self?.showSettings() }
                if command == "hosts-test" { self?.hostsTest() }
                if let command, command.hasPrefix("rename ") {
                    // "rename <id|mac> <name>"; an empty name resets it.
                    let parts = command.dropFirst(7).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    if let id = parts.first { self?.rename(String(id), to: parts.count > 1 ? String(parts[1]) : "") }
                }
                if command == "dock-on" { self?.showDockIcon = true }
                if command == "dock-off" { self?.showDockIcon = false }
                if command == "menubar-on" { self?.showMenuBarIcon = true }
                if command == "menubar-off" { self?.showMenuBarIcon = false }
                if command == "pair" { self?.startPairing() }
                if command == "diagnostics-on" || command == "diagnostics-off" {
                    self?.setDiagnostics(command == "diagnostics-on")
                }
                if let command, command.hasPrefix("remove ") { self?.removePeer(String(command.dropFirst(7))) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hidpp.restore()
                self?.capture.uninstall()
            }
        }
        Log.write("started", "version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "dev")")
    }

    private func installTapWhenAllowed() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted, capture.install() {
            Log.write("tap_installed")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installTapWhenAllowed() }
    }

    private func startRawKeyboardWhenAllowed() {
        inputMonitoringGranted = RawKeyboard.accessGranted
        if inputMonitoringGranted, rawKeyboard.start() {
            hidpp.onControl = { [unowned self] cid, down in
                guard down, let action = KeyAction.controls[cid] else { return }
                capture.perform(action)
            }
            hidpp.onReady = { [unowned self] in readHosts(keyboard: true) }
            for device in [mouseHidpp, boltMouse] {
                device.onReady = { [unowned self] in mouse = device; readHosts(keyboard: false) }
                device.onDetach = { [unowned self] in
                    if mouse === device { mouse = nil; mouseHosts = nil; updateEasySwitchNote(); applyShareChannel() }
                    // The Bluetooth mouse left: it may have switched to the Bolt channel, whose receiver
                    // stays plugged in and says nothing, so ask it.
                    if device === mouseHidpp, boltMouse.isReady {
                        mouse = boltMouse
                        readHosts(keyboard: false)
                    }
                }
            }
            // A device on another computer cannot be sent anywhere at sleep.
            hidpp.onAttach = { [unowned self] in
                keyboardHere = true
                keyboardArrived = Date()
                applyShareChannel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 61) { [weak self] in self?.applyShareChannel() }
            }
            hidpp.onDetach = { [unowned self] in
                keyboardHere = false
                keyboardHosts = nil
                updateEasySwitchNote()
                applyShareChannel()
            }
            hidpp.start(productID: 0xB35B, divert: Array(KeyAction.controls.keys)) // MX Keys
            mouseHidpp.start(productID: 0xB037, divert: []) // MX Anywhere 3S over Bluetooth
            boltMouse.startReceiver(deviceName: "Anywhere")  // ... or through a Bolt receiver
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startRawKeyboardWhenAllowed() }
    }

    // MARK: Easy-Switch when the Mac sleeps

    /// Reads a device's channels when it connects. The keyboard coming back also ends a sleep handoff.
    private func readHosts(keyboard: Bool, attempt: Int = 0) {
        guard let device = keyboard ? hidpp : mouse else { return }
        device.hostInfo { [weak self] info in
            guard let self else { return }
            guard let info else {
                // A device asleep (a Bolt mouse soon after it stops moving) does not answer: ask again.
                let delays: [TimeInterval] = [2, 5, 10, 20, 30]
                guard attempt < delays.count else {
                    Log.write("hidpp_hosts", "\(device.productName) no answer")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
                    guard let self, device === (keyboard ? hidpp : mouse) else { return }
                    readHosts(keyboard: keyboard, attempt: attempt + 1)
                }
                return
            }
            device.hostNames(count: info.count) { [weak self] names in
                guard let self else { return }
                Log.write("hidpp_hosts", "\(device.productName) current=\(info.current) count=\(info.count) " +
                          (0..<info.count).map { "\($0)=\(names[$0] ?? "?")" }.joined(separator: " "))
                let hosts = Hosts(current: info.current, count: info.count, names: names)
                if keyboard { keyboardHosts = hosts } else { mouseHosts = hosts; mouseHostsReadAt = Date() }
                if keyboard { rememberChannels(names) }
                if keyboard, names.isEmpty, attempt < 3 {
                    // Just connected, the keyboard sometimes has no names yet; the sleep hand-off needs them.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, device === hidpp else { return }
                        readHosts(keyboard: true, attempt: attempt + 1)
                    }
                }
                // A Bolt mouse that moved away leaves no trace: confirm it when the keyboard arrives.
                if keyboard, mouse === boltMouse { readHosts(keyboard: false) }
                applyShareChannel()
                if keyboard, away != nil {
                    Log.write("sleep_handoff_returned")
                    away = nil
                    reclaimUntil = nil
                }
                updateEasySwitchNote()
            }
        }
    }

    /// Remembers which keyboard channel each PC is on (matched by computer name), so the sleep
    /// hand-off works even when the keyboard does not report names.
    private func rememberChannels(_ names: [Int: String]) {
        var changed = false
        for i in settings.peers.indices {
            guard let channel = names.first(where: { $0.value.caseInsensitiveCompare(settings.peers[i].name) == .orderedSame })?.key,
                  settings.peers[i].keyboardHost != channel else { continue }
            settings.peers[i].keyboardHost = channel
            changed = true
        }
        if changed { settings.save() }
    }

    /// The PC to hand the devices to: online, preferably the one the pointer was on, and found on the
    /// keyboard's channel list by name (or by the channels it reported itself).
    private func sleepTarget() -> (peer: PeerConfig, keyboard: Int, mouse: Int?)? {
        guard let kb = keyboardHosts else { return nil }
        let preferred = remoteID ?? lastRemoteID
        let online = settings.peers.filter { server.isConnected($0.id) }
            .sorted { ($0.id == preferred ? 0 : 1) < ($1.id == preferred ? 0 : 1) }
        for peer in online {
            let byName = kb.names.first { $0.value.caseInsensitiveCompare(peer.name) == .orderedSame }?.key
            guard let keyboard = peer.keyboardHost ?? byName, keyboard != kb.current else { continue }
            // Until the PC reports the mouse's channel, assume it matches the keyboard's.
            let mouse = mouseHosts == nil ? nil : peer.mouseHost ?? keyboard
            return (peer, keyboard, mouse)
        }
        return nil
    }

    private func updateEasySwitchNote() {
        let devices = mouseHosts == nil ? "The keyboard goes" : "The keyboard and mouse go"
        let come = mouseHosts == nil ? "comes" : "come"
        if keyboardHosts == nil {
            easySwitchNote = "Needs an MX Keys connected to this Mac."
        } else if let target = sleepTarget() {
            easySwitchNote = "\(devices) to \(target.peer.displayName) (Easy-Switch \(target.keyboard + 1)) and \(come) back when the Mac wakes."
        } else {
            easySwitchNote = "No online PC matches one of the keyboard’s Easy-Switch channels."
        }
    }

    private func handleSleep(_ done: @escaping () -> Void) {
        guard settings.sleepHandoff, let kb = keyboardHosts, let target = sleepTarget() else {
            done()
            return
        }
        if capture.published.mode == .remote { capture.returnLocal(yMm: nil, reason: "sleep") }
        away = (target.peer.id, kb.current, mouseHosts?.current)
        reclaimUntil = nil
        Log.write("sleep_handoff", "to=\(target.peer.name) keyboard=\(target.keyboard) mouse=\(target.mouse.map(String.init) ?? "-")")
        hidpp.changeHost(to: target.keyboard)
        if let channel = target.mouse { mouse?.changeHost(to: channel) }
        // Let the commands leave before the Bluetooth radio powers down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
    }

    /// The screens woke (a real wake, not a dark wake): ask the PC to send the devices back. The old
    /// session may be dead until the network is back, so `heartbeat` keeps asking over a live one.
    private func handleWake() {
        guard away != nil else { return }
        reclaimUntil = Date().addingTimeInterval(60)
        nextReclaim = .distantPast
    }

    /// Development: asks each PC which channels the devices use there, without switching anything.
    private func hostsTest() {
        var message = MessageWriter(.reclaim)
        message.u8(0xFF)
        message.u8(0xFF)
        for id in server.connectedPeers where server.isModern(id) { server.send(message, to: id) }
        Log.write("hosts_test")
    }

    private func returnDevices() {
        guard let until = reclaimUntil, let away else { return }
        if Date() > until {
            Log.write("sleep_handoff_reclaim_gave_up")
            reclaimUntil = nil
            return
        }
        // Only over a session that has answered a ping since the wake.
        guard Date() >= nextReclaim, server.isModern(away.peer), isAvailable(away.peer) else { return }
        nextReclaim = Date().addingTimeInterval(4)
        var message = MessageWriter(.reclaim)
        message.u8(UInt8(away.keyboard))
        message.u8(away.mouse.map(UInt8.init) ?? 0xFF)
        server.send(message, to: away.peer)
        Log.write("sleep_handoff_reclaim", "keyboard=\(away.keyboard) mouse=\(away.mouse.map(String.init) ?? "-")")
    }

    /// Tells the tap thread which PC it may cross to on each side of the Mac: up (answered a ping in
    /// the last 1.5 s) and enabled. Runs with every heartbeat and whenever PCs or the layout change.
    /// The Easy-Switch channel the keyboard on this Mac uses now (0-based), if known.
    var currentChannel: Int? { keyboardHosts?.current }
    /// The keyboard is connected to this Mac (on some channel), since when.
    private var keyboardHere = false
    private var keyboardArrived = Date.distantPast

    /// With a sharing channel chosen, sharing needs the keyboard on this Mac on that channel: on
    /// another channel, or gone to another computer (channel 3), Unictrl pauses, so the built-in
    /// trackpad cannot move the PC's pointer either. The mouse does not decide: a Bolt mouse that
    /// switched away leaves its receiver behind, so its absence cannot be seen.
    var channelAllowsSharing: Bool {
        guard let wanted = settings.shareChannel else { return true }
        guard keyboardHere else { return false }
        // Channel not read yet: wait for it (a keyboard arriving on channel 1 must not share for the
        // second it takes), unless it cannot be read at all.
        guard let current = currentChannel else { return Date().timeIntervalSince(keyboardArrived) > 60 }
        return current == wanted
    }

    /// The channel changed (or the choice did): stop or resume crossing to the PCs.
    private var loggedSharing: Bool?
    /// nil until the first check after launch, so starting Unictrl makes no sound.
    private var wasReady: Bool?
    private var mouseHostsReadAt = Date.distantPast

    /// Keyboard and mouse both on the sharing channel: the full Unictrl setup is ready.
    private var devicesReady: Bool {
        guard let wanted = settings.shareChannel else { return false }
        // A Bluetooth mouse disconnects when it switches away; a Bolt mouse must have answered lately.
        let mouseFresh = mouse !== boltMouse || Date().timeIntervalSince(mouseHostsReadAt) < 20
        return keyboardHere && currentChannel == wanted && mouseHosts?.current == wanted && mouseFresh
    }

    private func chimeIfReady() {
        let ready = devicesReady
        defer { wasReady = ready }
        guard wasReady == false, ready else { return }
        Log.write("devices_ready", "channel=\((settings.shareChannel ?? 0) + 1)")
        if settings.readySound { NSSound(named: settings.readySoundName)?.play() }
    }

    private func applyShareChannel() {
        chimeIfReady()
        if loggedSharing != channelAllowsSharing {
            loggedSharing = channelAllowsSharing
            Log.write(channelAllowsSharing ? "sharing_resumed" : "sharing_paused", statusLine)
        }
        if !channelAllowsSharing { capture.returnLocal(yMm: nil, reason: "channel") }
        pushTargets()
        objectWillChange.send()
    }

    private func pushTargets() {
        var targets: [Side: [RemoteTarget]] = [:]
        if enabled && channelAllowsSharing {
            for side in Side.allCases {
                targets[side] = settings.arrangement.neighbors(of: Arrangement.mac, on: side, sizes: screenSizes).compactMap { target($0) }
            }
        }
        capture.setTargets(targets)
    }

    private func heartbeat() {
        pushTargets()
        let remote = capture.published.remote?.id
        for id in server.connectedPeers where id != remote { ping(id) } // the remote PC is pinged faster
        returnDevices()
        if let id = capture.published.remote?.id, disconnectGrace == nil,
           Date().timeIntervalSince(lastPong[id] ?? .distantPast) > 1.5 {
            capture.returnLocal(yMm: nil, reason: "peer_timeout")
        }
    }

    private func ping(_ id: String) {
        var ping = MessageWriter(.ping)
        ping.u64(DispatchTime.now().uptimeNanoseconds)
        server.send(ping, to: id)
    }

    private func pingRemote() {
        if let id = capture.published.remote?.id { ping(id) }
    }

    /// Grades every PC and sends each its report.
    private func updateQuality() {
        quality.mouseLink = mouse == nil ? .unknown : mouse === boltMouse ? .bolt : .bluetooth
        quality.macLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let peers = server.connectedPeers
        if Date().timeIntervalSince(macLinkReadAt) >= 5, let id = capture.published.remote?.id ?? peers.first {
            macLinkReadAt = Date()
            quality.macLink = MacNetwork.link(over: server.interfaceType(id))
        }
        quality.refresh(online: Set(peers))
        for id in peers where server.isModern(id) && quality.reportsStats(id) {
            guard var report = quality.reports[id] else { continue }
            if report.tips == sentTips[id] { report.tips = nil } else { sentTips[id] = report.tips }
            guard let json = try? JSONEncoder().encode(report) else { continue }
            var message = MessageWriter(.quality)
            message.bytes(json)
            server.send(message, to: id)
        }
    }

    private func handle(_ data: Data, from id: String) {
        var reader = MessageReader(data)
        switch reader.type {
        case .leave:
            guard let current = capture.published.remote, current.id == id else { break }
            let yMm = reader.f32().map(Double.init)
            // v1 PCs only leave back the way the pointer came in.
            let side = reader.u8().flatMap(Side.init(rawValue:)) ?? capture.published.entryEdge
            let row = settings.arrangement
            guard let here = row.rectangles(sizes: screenSizes)[id] else { break }
            let along = (yMm ?? 0) + (side.horizontal ? here.midY : here.midX)
            let next = row.neighbors(of: id, on: side, sizes: screenSizes, coordinate: along).first
            if let next, next != Arrangement.mac, let target = target(next, requireFresh: false) {
                let offset = side.horizontal ? target.offsetMm : target.xMm
                capture.switchRemote(to: target, yMm: along - offset, edge: side.opposite)
                remoteID = target.id
                lastRemoteID = target.id
            } else if next == Arrangement.mac {
                capture.returnLocal(yMm: along, reason: "leave", macEdge: side.opposite)
            } else if let target = target(id, requireFresh: false) {
                capture.resumeRemote(target)
            } else {
                capture.returnLocal(yMm: nil, reason: "unavailable")
            }
        case .screen:
            if let width = reader.f32(), let height = reader.f32(), width > 50, height > 30,
               let i = settings.peers.firstIndex(where: { $0.id == id }) {
                let (w, h) = (Double(width), Double(height))
                if abs(settings.peers[i].widthMm - w) > 0.5 || abs(settings.peers[i].heightMm - h) > 0.5 {
                    settings.peers[i].widthMm = w
                    settings.peers[i].heightMm = h
                    settings.save()
                    broadcastArrangement()
                    objectWillChange.send()
                }
            }
        case .arrangementEdit:
            if let edit = try? JSONDecoder().decode(Arrangement.self, from: reader.rest()),
               Set(edit.order) == Set(settings.arrangement.order), edit.order.count == settings.arrangement.order.count {
                setArrangement(edit)
            } else {
                sendArrangement(to: id) // put the PC's view back
            }
        case .rename:
            // A PC renamed a screen (itself, the Mac or another PC); only screens in the row.
            if let request = try? JSONDecoder().decode(RenameRequest.self, from: reader.rest()),
               settings.arrangement.order.contains(request.id) {
                rename(request.id, to: request.name)
            }
        case .hosts:
            // The PC saw the devices: remember their channels for it.
            guard let i = settings.peers.firstIndex(where: { $0.id == id }) else { break }
            if let k = reader.u8(), k != 0xFF { settings.peers[i].keyboardHost = Int(k) }
            if let m = reader.u8(), m != 0xFF { settings.peers[i].mouseHost = Int(m) }
            settings.save()
            Log.write("peer_hosts", "keyboard=\(settings.peers[i].keyboardHost.map(String.init) ?? "-") mouse=\(settings.peers[i].mouseHost.map(String.init) ?? "-")")
            updateEasySwitchNote()
        case .pong:
            lastPong[id] = Date()
            if let sent = reader.u64() {
                let precise = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000
                quality.addRTT(id, ms: precise)
                let ms = Int(precise)
                if latency[id] != ms {
                    latency[id] = ms
                    refreshDevices()
                }
            }
        case .stats:
            if let stats = try? JSONDecoder().decode(PcStats.self, from: reader.rest()) {
                quality.addStats(stats, from: id)
                if stats.hitches > 0 || stats.slowInjects > 0 {
                    Log.diagnostic("pc_stats", String(format: "moves=%d hitches=%d jitter_max=%.1f slow=%d inject_max=%.1f",
                                                 stats.moves, stats.hitches, stats.jitterMaxMs, stats.slowInjects, stats.injectMaxMs))
                }
            }
        default:
            break
        }
    }

}
