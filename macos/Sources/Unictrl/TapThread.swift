import Foundation

/// A dedicated high-priority thread with its own run loop for the event tap, so a busy main thread
/// (SwiftUI, IOKit, logging) can neither delay input nor get the tap disabled for timing out.
final class TapThread: Thread {
    private var loop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "Unictrl event tap"
        qualityOfService = .userInteractive
        start()
        started.wait()
    }

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive when no tap is installed yet.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while !isCancelled { CFRunLoopRun() }
    }

    var runLoop: CFRunLoop { loop! }

    /// Runs `block` on this thread, soon.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `block` on this thread and waits for its result.
    func performAndWait<T>(_ block: @escaping () -> T) -> T {
        if Thread.current === self { return block() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        perform {
            result = block()
            done.signal()
        }
        done.wait()
        return result!
    }
}
