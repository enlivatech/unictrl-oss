import Foundation

/// What a PC measured over the last second (0x22). Every field may be missing.
struct PcStats: Codable, Equatable {
    /// Moves that arrived.
    var moves = 0
    /// Delay spikes: moves that arrived 20 ms or more later than the steady one-way delay.
    var hitches = 0
    var jitterMaxMs = 0.0
    var jitterP95Ms = 0.0
    /// Moves that took 8 ms or more to apply, and the slowest one.
    var slowInjects = 0
    var injectMaxMs = 0.0
    /// The PC's connection to the Mac: "wifi", "ethernet" or "other".
    var link: String?
    var linkMbps: Int?
    /// 0–5 on Wi-Fi.
    var signalBars: Int?
    var onBattery: Bool?
    var batterySaver: Bool?
    /// Windows power mode: "efficiency", "balanced" or "performance".
    var powerMode: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moves = try c.decodeIfPresent(Int.self, forKey: .moves) ?? 0
        hitches = try c.decodeIfPresent(Int.self, forKey: .hitches) ?? 0
        jitterMaxMs = try c.decodeIfPresent(Double.self, forKey: .jitterMaxMs) ?? 0
        jitterP95Ms = try c.decodeIfPresent(Double.self, forKey: .jitterP95Ms) ?? 0
        slowInjects = try c.decodeIfPresent(Int.self, forKey: .slowInjects) ?? 0
        injectMaxMs = try c.decodeIfPresent(Double.self, forKey: .injectMaxMs) ?? 0
        link = try c.decodeIfPresent(String.self, forKey: .link)
        linkMbps = try c.decodeIfPresent(Int.self, forKey: .linkMbps)
        signalBars = try c.decodeIfPresent(Int.self, forKey: .signalBars)
        onBattery = try c.decodeIfPresent(Bool.self, forKey: .onBattery)
        batterySaver = try c.decodeIfPresent(Bool.self, forKey: .batterySaver)
        powerMode = try c.decodeIfPresent(String.self, forKey: .powerMode)
    }
}

/// Where a hitch came from, along the way from the mouse to the PC's cursor.
enum HitchSource: String, Codable, CaseIterable {
    /// The mouse's radio link to the Mac paused (reports arrived in a burst).
    case mouse
    /// The Mac handed the event to Unictrl late.
    case mac
    /// The move reached the PC late: Wi-Fi, the router, either computer's network stack.
    case network
    /// The PC took long to apply the move.
    case pc
}

/// How the pointer on one PC is doing (0x23 to the PC, and the Mac's Settings).
struct QualityReport: Codable, Equatable {
    enum Grade: String, Codable { case idle, smooth, fair, poor }
    struct Rates: Codable, Equatable {
        var mouse = 0.0, mac = 0.0, network = 0.0, pc = 0.0
        var total: Double { mouse + mac + network + pc }
        subscript(source: HitchSource) -> Double {
            switch source {
            case .mouse: mouse
            case .mac: mac
            case .network: network
            case .pc: pc
            }
        }
    }

    var grade: Grade
    /// Round trip now (median of the last two seconds) and its 95th percentile over the window.
    var rttMs: Double?
    var rttP95Ms: Double?
    /// Seconds of pointer movement on this PC in the window.
    var movingSeconds: Int
    /// Hitches per minute of movement, by where they came from.
    var hitchesPerMin: Rates
    /// The full checklist; nil when unchanged since the last report sent to the PC.
    var tips: [Tip]?
    /// Hitches since the previous report, for the PC's own graph; nil when none.
    var recentHitches: [HitchSource]? = nil
}

/// The Mac's own network connection to a PC.
struct MacLink: Equatable {
    enum Kind: String { case wifi, ethernet, other }
    var kind: Kind
    /// 2.4, 5 or 6 (GHz) on Wi-Fi.
    var bandGHz: Double?
    var channel: Int?
    var widthMHz: Int?
    var rssi: Int?
    var noise: Int?
}

enum MouseLink { case bolt, bluetooth, unknown }

/// Collects round trips, the Mac's mouse windows and the PCs' stats; grades each PC once a second.
/// Main thread only.
@MainActor final class QualityMonitor: ObservableObject {
    struct Sample { let at: Date; let ms: Double }
    struct Hitch { let at: Date; let source: HitchSource }

    @Published private(set) var reports: [String: QualityReport] = [:]

    /// How far back grades and rates look.
    static let window: TimeInterval = 60
    /// Rates are taken over at least this much movement, so one hitch in a short wiggle reads as rare.
    static let minMovingSeconds = 30.0

    var mouseLink = MouseLink.unknown
    var macLink: MacLink?
    var macLowPower = false
    var pcName: (String) -> String = { _ in "the PC" }

    private struct Peer {
        var rtt: [Sample] = []
        var hitches: [Hitch] = []
        var moving: [Date] = []
        var stats: PcStats?
        /// Round trips right after connecting include the connection's own start-up; skip them.
        var settlesAt = Date.distantPast
    }
    private var peers: [String: Peer] = [:]
    private var lastRefresh = Date.distantPast

    func addRTT(_ peer: String, ms: Double, at: Date = Date()) {
        guard at >= peers[peer]?.settlesAt ?? .distantPast else { return }
        peers[peer, default: Peer()].rtt.append(Sample(at: at, ms: ms))
    }

    /// A PC (re)connected: start its round trips afresh once the new connection has settled.
    func connected(_ peer: String, at: Date = Date()) {
        peers[peer, default: Peer()].rtt = []
        peers[peer]?.settlesAt = at.addingTimeInterval(3)
    }

    /// About a second of mouse movement while the pointer was on `peer`.
    func addMouseWindow(_ peer: String, events: Int, stalls: Int, late: Int, at: Date = Date()) {
        var p = peers[peer, default: Peer()]
        if events >= 20 { p.moving.append(at) }
        p.hitches += Array(repeating: Hitch(at: at, source: .mouse), count: stalls)
        p.hitches += Array(repeating: Hitch(at: at, source: .mac), count: late)
        peers[peer] = p
    }

    func addStats(_ stats: PcStats, from peer: String, at: Date = Date()) {
        var p = peers[peer, default: Peer()]
        p.hitches += Array(repeating: Hitch(at: at, source: .network), count: stats.hitches)
        p.hitches += Array(repeating: Hitch(at: at, source: .pc), count: stats.slowInjects)
        // Keep what the PC knows about itself when a second carried no environment.
        var merged = stats
        if let old = p.stats {
            merged.link = stats.link ?? old.link
            merged.linkMbps = stats.linkMbps ?? old.linkMbps
            merged.signalBars = stats.signalBars ?? old.signalBars
            merged.onBattery = stats.onBattery ?? old.onBattery
            merged.batterySaver = stats.batterySaver ?? old.batterySaver
            merged.powerMode = stats.powerMode ?? old.powerMode
        }
        p.stats = merged
        peers[peer] = p
    }

    func forget(_ peer: String) {
        peers[peer] = nil
        reports[peer] = nil
    }

    /// Whether the PC reports stats, i.e. understands quality reports.
    func reportsStats(_ peer: String) -> Bool { peers[peer]?.stats != nil }

    /// Round trips and hitches of the last minute, for the live graph.
    func history(_ peer: String) -> (rtt: [Sample], hitches: [Hitch]) {
        (peers[peer]?.rtt ?? [], peers[peer]?.hitches ?? [])
    }

    func stats(_ peer: String) -> PcStats? { peers[peer]?.stats }

    /// Drops old samples and grades every PC with data.
    func refresh(online: Set<String>, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.window)
        var next: [String: QualityReport] = [:]
        for id in Array(peers.keys) {
            guard var p = peers[id] else { continue }
            p.rtt.removeAll { $0.at < cutoff }
            p.hitches.removeAll { $0.at < cutoff }
            p.moving.removeAll { $0 < cutoff }
            peers[id] = p
            guard online.contains(id) else { continue }
            var report = Self.grade(p, pcName: pcName(id), mouse: mouseLink, mac: macLink, macLowPower: macLowPower, now: now)
            let recent = p.hitches.filter { $0.at > lastRefresh }.map(\.source)
            report.recentHitches = recent.isEmpty ? nil : recent
            next[id] = report
        }
        lastRefresh = now
        if next != reports { reports = next }
    }

    private static func grade(_ p: Peer, pcName: String, mouse: MouseLink, mac: MacLink?, macLowPower: Bool, now: Date) -> QualityReport {
        let recent = p.rtt.filter { $0.at > now.addingTimeInterval(-2) }.map(\.ms).sorted()
        let all = p.rtt.map(\.ms).sorted()
        func percentile(_ values: [Double], _ q: Double) -> Double? {
            values.isEmpty ? nil : values[min(values.count - 1, Int(q * Double(values.count)))]
        }
        let moving = p.moving.count
        let minutes = max(Double(moving), minMovingSeconds) / 60
        var rates = QualityReport.Rates()
        for source in HitchSource.allCases {
            let n = Double(p.hitches.filter { $0.source == source }.count) / minutes
            switch source {
            case .mouse: rates.mouse = n
            case .mac: rates.mac = n
            case .network: rates.network = n
            case .pc: rates.pc = n
            }
        }
        let p95 = percentile(all, 0.95)
        let grade: QualityReport.Grade
        if moving < 3 && p.hitches.isEmpty && (p95 ?? 0) <= 20 {
            grade = .idle
        } else if rates.total <= 3 && (p95 ?? 0) <= 20 {
            grade = .smooth
        } else if rates.total <= 10 && (p95 ?? 0) <= 50 {
            grade = .fair
        } else {
            grade = .poor
        }
        let tips = Tips.evaluate(.init(rates: rates, movingSeconds: moving, rttP95Ms: p95, mouse: mouse, mac: mac,
                                       macLowPower: macLowPower, pc: p.stats, pcName: pcName))
        return QualityReport(grade: grade, rttMs: percentile(recent, 0.5), rttP95Ms: p95, movingSeconds: moving,
                             hitchesPerMin: rates, tips: tips)
    }
}
