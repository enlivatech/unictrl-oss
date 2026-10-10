import Foundation

/// Plain-text diagnostics at ~/Library/Logs/Unictrl.log. Never logs keystrokes or the pairing key.
enum Log {
    private static let queue = DispatchQueue(label: "unictrl.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Unictrl.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// `UnictrlSettings.diagnostics`: extra lines for chasing pointer hitches. Set on the main thread,
    /// read anywhere; a stale read only costs or skips one line.
    static var diagnostics = false

    /// A diagnostics-only line: written only while `diagnostics` is on.
    static func diagnostic(_ event: String, _ detail: @autoclosure () -> String = "") {
        if diagnostics { write(event, detail()) }
    }

    static func write(_ event: String, _ detail: String = "") {
        let line = "\(formatter.string(from: Date())) \(event) \(detail)\n"
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 8_000_000 { // about a day with diagnostics on
                let previous = url.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: url, to: previous)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
