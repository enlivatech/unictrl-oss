import CoreGraphics
import Foundation
import QuartzCore

/// Mouse-wheel smoothing, as Mos did: each notch becomes a short eased glide instead of a jump.
/// Amounts are added as they arrive; a 120 Hz timer hands out an exponentially decaying share of what
/// is left, so fast spinning keeps momentum and a single notch settles in about a quarter second.
/// Runs on its own serial queue (callers may be on any thread); `emit` is called there.
final class ScrollSmoother {
    private let queue = DispatchQueue(label: "unictrl.scroll", qos: .userInteractive)
    /// Receives the next step (dx, dy) in the caller's units.
    var emit: (Double, Double) -> Void = { _, _ in }
    /// Time constant of the glide; ~3 of these to settle.
    var tau: Double = 0.085

    private var pending = (x: 0.0, y: 0.0)
    private var timer: DispatchSourceTimer?
    private var lastTick = CACurrentMediaTime()

    func add(dx: Double, dy: Double) {
        queue.async { [self] in addNow(dx: dx, dy: dy) }
    }

    /// Drops whatever is still gliding (e.g. the pointer moved to the other computer).
    func stop() {
        queue.async { [self] in stopNow() }
    }

    private func addNow(dx: Double, dy: Double) {
        pending.x += dx
        pending.y += dy
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func stopNow() {
        timer?.cancel()
        timer = nil
        pending = (0, 0)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let share = 1 - exp(-(now - lastTick) / tau)
        lastTick = now
        var step = (x: pending.x * share, y: pending.y * share)
        // Finish off the tail instead of creeping.
        if abs(pending.x - step.x) < 0.3 && abs(pending.y - step.y) < 0.3 {
            step = pending
        }
        pending.x -= step.x
        pending.y -= step.y
        if step.x != 0 || step.y != 0 { emit(step.x, step.y) }
        if pending.x == 0 && pending.y == 0 { stopNow() }
    }
}

/// Posts pixel scroll events on the Mac, tagged so Unictrl's own tap ignores them.
enum ScrollPoster {
    static let tag: Int64 = 0x554E_4943 // "UNIC"
    private static var remainder = (x: 0.0, y: 0.0)

    static func post(dx: Double, dy: Double) {
        remainder.x += dx
        remainder.y += dy
        let x = Int32(remainder.x.rounded(.towardZero))
        let y = Int32(remainder.y.rounded(.towardZero))
        remainder.x -= Double(x)
        remainder.y -= Double(y)
        guard x != 0 || y != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.post(tap: .cgSessionEventTap)
    }
}
