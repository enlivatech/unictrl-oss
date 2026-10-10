// Renders Unictrl's SwiftUI windows to PNG without a visible screen (for reviews and screenshots).
//   swiftc -O -parse-as-library -o /tmp/ui-snapshot ../../macos/Sources/Unictrl/{ArrangementWindow,PairingWindow,Log}.swift main.swift
//   /tmp/ui-snapshot <out-dir>
import AppKit
import SwiftUI

@main struct Snapshot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        for appearance in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            let arrange = ArrangementWindow()
            arrange.macName = "MacBook Pro"
            arrange.peerName = "SURFACE-LAPTOP"
            arrange.macSize = CGSize(width: 302, height: 196)
            arrange.peerSize = CGSize(width: 291, height: 194)
            for (side, offset) in [("right", 0.0), ("left", 45.0)] {
                arrange.side = side
                arrange.offsetMm = offset
                save(ArrangementView(model: arrange), to: dir.appendingPathComponent("arrange-\(side)-\(appearance).png"))
            }
            let pairing = PairingWindow()
            pairing.show(code: "482915")
            save(PairingView(model: pairing), to: dir.appendingPathComponent("pairing-\(appearance).png"))
        }
        exit(0)
    }

    @MainActor static func save<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.lastPathComponent, Int(host.frame.width), "x", Int(host.frame.height))
    }
}
