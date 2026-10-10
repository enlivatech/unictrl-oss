import AppKit
import SwiftUI

/// Shows the 6-digit code while a Windows PC pairs. Closing it cancels pairing.
@MainActor final class PairingWindow: NSObject, NSWindowDelegate, ObservableObject {
    enum State { case waiting, paired, expired }

    @Published private(set) var code = ""
    @Published private(set) var state = State.waiting
    @Published private(set) var secondsLeft = 120
    var onClose: (() -> Void)?

    private var window: NSWindow?
    private var timer: Timer?

    func show(code: String) {
        self.code = code
        state = .waiting
        secondsLeft = 120
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 230),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pair Windows PC"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: PairingView(model: self))
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .waiting else { return }
                self.secondsLeft -= 1
                if self.secondsLeft <= 0 { self.expire() }
            }
        }
    }

    func paired() {
        state = .paired
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.window?.close() }
    }

    /// The code was voided (too many wrong attempts) or ran out.
    func expire() {
        state = .expired
        timer?.invalidate()
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        if state == .waiting { onClose?() }
    }
}

struct PairingView: View {
    @ObservedObject var model: PairingWindow

    var body: some View {
        VStack(spacing: 14) {
            switch model.state {
            case .waiting:
                Text("Enter this code in Unictrl on your Windows PC")
                    .font(.callout).foregroundStyle(.secondary)
                Text(model.code.prefix(3) + " " + model.code.suffix(3))
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    .textSelection(.enabled)
                Text("Expires in \(model.secondsLeft / 60):\(String(format: "%02d", model.secondsLeft % 60))")
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            case .paired:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text("Paired").font(.title3.weight(.semibold))
            case .expired:
                Image(systemName: "clock.badge.xmark").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("This code is no longer valid.").font(.callout)
                Text("Choose Pair Windows PC… again for a new code.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 360, height: 230)
    }
}
