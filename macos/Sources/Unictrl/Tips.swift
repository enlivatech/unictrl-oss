import Foundation

/// One item of the optimisation checklist. The Mac decides every item and sends the list to the PC,
/// so the text lives only here.
struct Tip: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        /// Worth doing now: measured hitches point here, or a setting is known to be off.
        case act
        /// Can't be checked from here, or not measured yet.
        case info
        /// Already fine.
        case ok
    }

    let id: String
    var status: Status
    let title: String
    /// One line: why it matters. The hover text.
    let summary: String
    /// How to do it, step by step.
    let steps: [String]
    /// What Unictrl measured, if anything.
    var seen: String?
}

enum Tips {
    struct Inputs {
        var rates: QualityReport.Rates
        var movingSeconds: Int
        var rttP95Ms: Double?
        var mouse: MouseLink
        var mac: MacLink?
        var macLowPower: Bool
        var pc: PcStats?
        var pcName: String
    }

    /// Hitches per minute from one source worth acting on.
    static let notableRate = 1.5
    /// Seconds of movement before measured items are judged.
    static let measuredAfter = 10

    /// The checklist, things to do first, then unknowns, then what is already fine.
    static func evaluate(_ x: Inputs) -> [Tip] {
        let measured = x.movingSeconds >= measuredAfter
        func notable(_ source: HitchSource) -> Bool { measured && x.rates[source] >= notableRate }
        func perMinute(_ source: HitchSource) -> String {
            measured ? String(format: "%.1f per minute of movement", x.rates[source]) : "Not measured yet: move the pointer on \(x.pcName) for a while"
        }
        let networkTrouble = notable(.network) || (x.rttP95Ms ?? 0) > 25
        let macWiFi = x.mac?.kind == .wifi
        let pcWiFi = x.pc?.link == "wifi"
        var tips: [Tip] = []

        // The mouse's radio.
        switch x.mouse {
        case .bluetooth:
            tips.append(Tip(id: "bolt", status: .act, title: "Connect the mouse with a Logi Bolt receiver",
                            summary: "Bluetooth shares this Mac’s radio with Wi‑Fi, AirDrop and Universal Control, so the pointer pauses now and then. A Bolt receiver has a radio of its own.",
                            steps: ["Plug the Logi Bolt receiver into this Mac (a short USB extension is even better).",
                                    "Pair the mouse to the receiver once in Logi Options+; afterwards no Logitech software is needed.",
                                    "Use that Easy‑Switch channel for this Mac. Unictrl finds the mouse through the receiver by itself."],
                            seen: "Mouse: Bluetooth"))
        case .bolt:
            tips.append(Tip(id: "bolt", status: .ok, title: "Mouse on a Logi Bolt receiver",
                            summary: "The receiver’s own radio keeps the mouse off this Mac’s busy Bluetooth and Wi‑Fi radio.",
                            steps: ["Nothing to do."], seen: "Mouse: Bolt receiver"))
        case .unknown:
            break
        }
        if x.mouse != .bluetooth {
            tips.append(Tip(id: "receiver-placement",
                            status: notable(.mouse) ? .act : measured ? .ok : .info,
                            title: "Keep the receiver close to the mouse",
                            summary: "The receiver’s 2.4 GHz signal is easily blocked by the laptop’s body and drowned out by noise from USB 3 devices.",
                            steps: ["Use the USB port on the side nearest the mouse.",
                                    "Better: a short USB extension cable, so the receiver sits on the desk in view of the mouse, 20–30 cm away.",
                                    "Keep it away from USB 3 hubs, docks, external SSDs and the Wi‑Fi router: USB 3 gives off noise right in the 2.4 GHz band."],
                            seen: "Mouse pauses: " + perMinute(.mouse)))
        }

        // This Mac's Wi-Fi.
        if let mac = x.mac, mac.kind == .wifi {
            let where_ = [mac.bandGHz.map { $0 == 2.4 ? "2.4 GHz" : String(format: "%.0f GHz", $0) },
                          mac.channel.map { "channel \($0)" }, mac.widthMHz.map { "\($0) MHz" }]
                .compactMap { $0 }.joined(separator: ", ")
            let band24 = mac.bandGHz == 2.4
            tips.append(Tip(id: "wifi-band", status: mac.bandGHz == nil ? .info : band24 ? .act : .ok,
                            title: "Use 5 GHz or 6 GHz Wi‑Fi",
                            summary: "2.4 GHz is slower and crowded, and it shares the air with Bluetooth and the mouse receiver.",
                            steps: ["Join the router’s 5 GHz (or 6 GHz) network on this Mac and on \(x.pcName).",
                                    "If the router uses one name for all bands, give 2.4 GHz its own name or turn on band steering.",
                                    "Forget the 2.4 GHz network on both computers so they don’t drift back to it."],
                            seen: where_.isEmpty ? nil : "This Mac: Wi‑Fi " + where_))
            if !band24 {
                let channel = mac.channel
                let preferred = channel.map { (149...165).contains($0) || (36...48).contains($0) }
                let radar = channel.map { (52...144).contains($0) } ?? false
                tips.append(Tip(id: "router-channel",
                                status: preferred == true ? .ok : radar ? .act : preferred == nil ? .info : (networkTrouble ? .act : .info),
                                title: "Set the router to channel 149 (or 36–48)",
                                summary: "AirDrop and Universal Control talk on channel 149 (44 in some regions). On the same channel this Mac doesn’t have to hop away from your Wi‑Fi, and channels outside 52–144 are never forced off by radar.",
                                steps: ["Open the router’s app or admin page, Wi‑Fi settings, the 5 GHz band.",
                                        "Change the channel from Auto to 149, or to one of 36–48 if 149 isn’t offered.",
                                        "Keep the width at 80 MHz: 160 MHz needs the radar channels.",
                                        "Both computers reconnect by themselves within a few seconds."],
                                seen: channel.map { "This Mac: channel \($0)" + (radar ? " (a radar channel)" : "") }))
            }
            if let rssi = mac.rssi {
                tips.append(Tip(id: "wifi-signal", status: rssi >= -67 ? .ok : rssi < -75 || networkTrouble ? .act : .info,
                                title: "Keep a strong Wi‑Fi signal",
                                summary: "A weak signal means resends, and every resend is a delay spike.",
                                steps: ["Aim for −65 dBm or better. Option‑click the Wi‑Fi icon in the menu bar to see it.",
                                        "Put the router or a mesh node in the same room, in the open: not behind the screen or in a cabinet.",
                                        "With mesh Wi‑Fi, make sure both computers use the node in this room."],
                                seen: "This Mac: \(rssi) dBm" + (mac.noise.map { ", noise \($0) dBm" } ?? "")))
            }
        }

        // The PC's connection.
        if let pc = x.pc, pc.link != nil {
            let pcSeen: String = {
                var parts = [pc.link == "wifi" ? "Wi‑Fi" : pc.link == "ethernet" ? "Ethernet" : "other network"]
                if let bars = pc.signalBars, pc.link == "wifi" { parts.append("\(bars) of 5 bars") }
                if let mbps = pc.linkMbps, mbps > 0 { parts.append(mbps >= 1000 ? String(format: "%.1f Gb/s", Double(mbps) / 1000) : "\(mbps) Mb/s") }
                return "\(x.pcName): " + parts.joined(separator: ", ")
            }()
            if pcWiFi, let bars = pc.signalBars {
                tips.append(Tip(id: "pc-signal", status: bars >= 4 ? .ok : bars <= 2 || networkTrouble ? .act : .info,
                                title: "Keep a strong Wi‑Fi signal on \(x.pcName)",
                                summary: "Laptops often have weaker Wi‑Fi antennas than Macs; the PC’s side of the link can be the weak one.",
                                steps: ["Move the PC or the router so they are in the same room with a clear line between them.",
                                        "Connect the PC to the same 5 GHz network and mesh node as this Mac."],
                                seen: pcSeen))
            }
            let wired = pc.link == "ethernet" || x.mac?.kind == .ethernet
            tips.append(Tip(id: "wired", status: wired && !networkTrouble ? .ok : networkTrouble ? .act : .info,
                            title: "Use a cable where you can",
                            summary: "With both computers on Wi‑Fi, every move crosses the air twice. A cable on either computer takes one of those trips off the air.",
                            steps: ["Plug the PC into the router or a switch; a USB‑C Ethernet adapter works if it has no port.",
                                    "This Mac can use one too. Both computers use the cable by themselves; Wi‑Fi can stay on.",
                                    "No cable possible? Keep both on the same 5 GHz network and the same mesh node."],
                            seen: pcSeen + (x.mac.map { ". This Mac: \($0.kind == .wifi ? "Wi‑Fi" : $0.kind == .ethernet ? "Ethernet" : "other")" } ?? "")))
            let saving = pc.onBattery == true || pc.batterySaver == true || pc.powerMode == "efficiency"
            let powerSeen = [pc.onBattery.map { $0 ? "on battery" : "plugged in" },
                             pc.batterySaver == true ? "battery saver on" : nil,
                             pc.powerMode.map { "power mode " + ($0 == "efficiency" ? "Best power efficiency" : $0 == "performance" ? "Best performance" : "Balanced") }]
                .compactMap { $0 }.joined(separator: ", ")
            tips.append(Tip(id: "pc-power",
                            status: saving ? .act : pc.powerMode == "performance" ? .ok : (networkTrouble || notable(.pc)) ? .act : .info,
                            title: "Set \(x.pcName) to Best performance",
                            summary: "To save power, Windows lets the Wi‑Fi adapter and the processor doze between packets, so moves arrive in bursts.",
                            steps: ["Settings › System › Power & battery › Power mode: Best performance (when plugged in).",
                                    "Keep the PC plugged in: battery saver holds back network and input work.",
                                    "Device Manager › Network adapters › the Wi‑Fi adapter › Power Management: clear “Allow the computer to turn off this device to save power”.",
                                    "Same adapter › Advanced: set MIMO Power Save Mode to “No SMPS” and, if listed, Roaming Aggressiveness to Lowest."],
                            seen: powerSeen.isEmpty ? nil : "\(x.pcName): \(powerSeen)"))
        }

        if macWiFi || x.mac?.kind == .other {
            tips.append(Tip(id: "vpn", status: x.mac?.kind == .other ? .act : .ok,
                            title: "Keep local traffic out of the VPN",
                            summary: "A VPN that carries local traffic sends every move through its tunnel, adding delay and spikes.",
                            steps: ["In the VPN app, allow local network access (often “Allow LAN” or “Local network sharing”).",
                                    "Or pause the VPN while you use Unictrl."],
                            seen: x.mac?.kind == .other ? "This Mac reaches \(x.pcName) through a tunnel" : "This Mac reaches \(x.pcName) directly"))
        }

        // The computers themselves.
        tips.append(Tip(id: "mac-low-power", status: x.macLowPower ? .act : .ok,
                        title: "Turn off Low Power Mode on this Mac",
                        summary: "Low Power Mode slows the processor and lets Wi‑Fi doze, which delays moves.",
                        steps: ["System Settings › Battery › Low Power Mode: Never, or Only on Battery and keep the Mac plugged in."],
                        seen: "This Mac: Low Power Mode \(x.macLowPower ? "on" : "off")"))
        tips.append(Tip(id: "mac-busy", status: notable(.mac) ? .act : measured ? .ok : .info,
                        title: "Keep this Mac responsive",
                        summary: "When the Mac is busy, mouse events reach Unictrl late.",
                        steps: ["Open Activity Monitor › CPU and sort by % CPU.",
                                "Quit or pause what uses a lot: a video export, indexing, a runaway browser tab.",
                                "Quit other tools that watch the keyboard and mouse (other KVM or macro utilities) if you don’t need them: each one handles every event."],
                        seen: "Late events: " + perMinute(.mac)))
        if x.pc != nil {
            tips.append(Tip(id: "pc-busy", status: notable(.pc) ? .act : measured ? .ok : .info,
                            title: "Keep \(x.pcName) responsive",
                            summary: "When the PC is busy, moves take long to apply.",
                            steps: ["Open Task Manager › Processes and sort by CPU.",
                                    "Close or pause what uses a lot, such as updates, scans or a game in the background."],
                            seen: "Slow moves: " + perMinute(.pc)))
        }

        // Feel, not lag.
        tips.append(Tip(id: "pointer-feel", status: .info, title: "If the pointer feels loose on the PC",
                        summary: "A pointer that runs on after fast moves is a speed setting, not lag.",
                        steps: ["Unictrl Settings › Pointer speed on PCs: try 90–95 %.",
                                "On the PC, Settings › Bluetooth & devices › Mouse › Additional mouse settings › Pointer Options: Enhance pointer precision on gives acceleration like a Mac’s, off a steadier, even feel. Try both."],
                        seen: nil))

        let order: [Tip.Status: Int] = [.act: 0, .info: 1, .ok: 2]
        return tips.enumerated().sorted { (order[$0.element.status]!, $0.offset) < (order[$1.element.status]!, $1.offset) }.map(\.element)
    }
}
