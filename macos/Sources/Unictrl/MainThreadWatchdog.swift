import Foundation

/// Diagnostics: logs when the main thread was stuck for 40 ms or more while the pointer is on a PC, to
/// tell the Mac's own pauses apart from the network's. Pings the main thread from a background timer.
/// Runs only while `Log.diagnostics` is on.
enum MainThreadWatchdog {
    private static let queue = DispatchQueue(label: "Unictrl main watchdog", qos: .utility)
    private static var timer: DispatchSourceTimer?
    /// Read and written on `queue` only.
    private static var pendingSince: UInt64?

    @MainActor static func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler {
            guard pendingSince == nil else { return }
            let sent = DispatchTime.now().uptimeNanoseconds
            pendingSince = sent
            DispatchQueue.main.async {
                let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                let remote = AppController.shared.isRemote
                queue.async { pendingSince = nil }
                if lag >= 40, remote { Log.write("main_stall", String(format: "ms=%.0f", lag)) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    @MainActor static func stop() {
        timer?.cancel()
        timer = nil
    }
}
