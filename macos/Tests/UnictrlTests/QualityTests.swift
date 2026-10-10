import Foundation
import Testing
@testable import Unictrl

@MainActor @Suite struct QualityTests {
    private let pc = "PC-1"
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// `seconds` seconds of movement on the PC with steady 4 ms round trips.
    private func moving(_ monitor: QualityMonitor, seconds: Int, stalls: [Int: Int] = [:]) {
        for s in 0..<seconds {
            let at = start.addingTimeInterval(Double(s))
            monitor.addMouseWindow(pc, events: 120, stalls: stalls[s] ?? 0, late: 0, at: at)
            for t in 0..<10 { monitor.addRTT(pc, ms: 4, at: at.addingTimeInterval(Double(t) / 10)) }
        }
    }

    @Test func idleUntilThePointerMoves() {
        let monitor = QualityMonitor()
        monitor.addRTT(pc, ms: 5, at: start)
        monitor.refresh(online: [pc], now: start.addingTimeInterval(1))
        #expect(monitor.reports[pc]?.grade == .idle)
        #expect(monitor.reports[pc]?.rttMs == 5)
    }

    @Test func steadyMovementIsSmooth() {
        let monitor = QualityMonitor()
        moving(monitor, seconds: 40, stalls: [10: 1])
        monitor.refresh(online: [pc], now: start.addingTimeInterval(40))
        let report = monitor.reports[pc]
        #expect(report?.grade == .smooth)
        #expect(report?.movingSeconds == 40)
        #expect(abs((report?.hitchesPerMin.mouse ?? 0) - 1.5) < 0.01)
    }

    @Test func networkSpikesFromThePcMakeItFair() {
        let monitor = QualityMonitor()
        moving(monitor, seconds: 60)
        var stats = PcStats()
        stats.moves = 120
        stats.hitches = 1
        for s in stride(from: 0, to: 60, by: 10) { monitor.addStats(stats, from: pc, at: start.addingTimeInterval(Double(s))) }
        monitor.refresh(online: [pc], now: start.addingTimeInterval(59.5))
        #expect(monitor.reports[pc]?.grade == .fair)
        #expect(monitor.reports[pc]?.hitchesPerMin.network == 6)
    }

    @Test func oldSamplesAgeOut() {
        let monitor = QualityMonitor()
        moving(monitor, seconds: 30, stalls: [0: 20])
        monitor.refresh(online: [pc], now: start.addingTimeInterval(120))
        #expect(monitor.history(pc).hitches.isEmpty)
        #expect(monitor.reports[pc]?.grade == .idle)
    }

    @Test func offlinePcsAreNotGraded() {
        let monitor = QualityMonitor()
        moving(monitor, seconds: 5)
        monitor.refresh(online: [], now: start.addingTimeInterval(5))
        #expect(monitor.reports[pc] == nil)
    }

    @Test func statsKeepTheLastKnownEnvironment() {
        let monitor = QualityMonitor()
        var first = PcStats()
        first.link = "wifi"
        first.powerMode = "efficiency"
        monitor.addStats(first, from: pc, at: start)
        monitor.addStats(PcStats(), from: pc, at: start.addingTimeInterval(1))
        #expect(monitor.stats(pc)?.link == "wifi")
        #expect(monitor.stats(pc)?.powerMode == "efficiency")
    }
}

@Suite struct TipsTests {
    private func inputs(_ change: (inout Tips.Inputs) -> Void = { _ in }) -> Tips.Inputs {
        var x = Tips.Inputs(rates: .init(), movingSeconds: 60, rttP95Ms: 6, mouse: .bolt,
                            mac: MacLink(kind: .wifi, bandGHz: 5, channel: 149, widthMHz: 80, rssi: -60, noise: -90),
                            macLowPower: false, pc: nil, pcName: "Laptop")
        change(&x)
        return x
    }

    private func status(_ id: String, _ tips: [Tip]) -> Tip.Status? { tips.first { $0.id == id }?.status }

    @Test func aGoodSetupPassesTheChecks() {
        let tips = Tips.evaluate(inputs())
        #expect(status("bolt", tips) == .ok)
        #expect(status("wifi-band", tips) == .ok)
        #expect(status("router-channel", tips) == .ok)
        #expect(status("wifi-signal", tips) == .ok)
        #expect(!tips.contains { $0.status == .act })
    }

    @Test func bluetoothMouseIsFlagged() {
        let tips = Tips.evaluate(inputs { $0.mouse = .bluetooth })
        #expect(tips.first?.id == "bolt")
        #expect(tips.first?.status == .act)
        #expect(status("receiver-placement", tips) == nil)
    }

    @Test func mousePausesPointAtTheReceiver() {
        let tips = Tips.evaluate(inputs { $0.rates.mouse = 4 })
        #expect(tips.first?.id == "receiver-placement")
    }

    @Test func radarChannelsAndTwoPointFourAreFlagged() {
        #expect(status("router-channel", Tips.evaluate(inputs { $0.mac?.channel = 100 })) == .act)
        let slow = Tips.evaluate(inputs { $0.mac?.bandGHz = 2.4; $0.mac?.channel = 6 })
        #expect(status("wifi-band", slow) == .act)
        #expect(status("router-channel", slow) == nil)
    }

    @Test func pcPowerSavingIsFlagged() {
        var pc = PcStats()
        pc.link = "wifi"
        pc.signalBars = 4
        pc.onBattery = true
        let tips = Tips.evaluate(inputs { $0.pc = pc })
        #expect(status("pc-power", tips) == .act)
        #expect(tips.first { $0.id == "pc-power" }?.title.contains("Laptop") == true)
        #expect(status("pc-signal", tips) == .ok)
    }

    @Test func notMeasuredYetIsInfoNotOk() {
        let tips = Tips.evaluate(inputs { $0.movingSeconds = 2; $0.rates.mouse = 30 })
        #expect(status("receiver-placement", tips) == .info)
        #expect(status("mac-busy", tips) == .info)
    }

    @Test func actionsComeFirstThenUnknownsThenPassed() {
        let tips = Tips.evaluate(inputs { $0.macLowPower = true })
        let order = tips.map(\.status)
        #expect(order == order.sorted { ["act": 0, "info": 1, "ok": 2][$0.rawValue]! < ["act": 0, "info": 1, "ok": 2][$1.rawValue]! })
        #expect(tips.first?.id == "mac-low-power")
    }

    @Test func aFullChecklistFitsInOneFrame() throws {
        var pc = PcStats()
        pc.link = "wifi"
        pc.signalBars = 2
        pc.linkMbps = 866
        pc.onBattery = true
        pc.batterySaver = true
        pc.powerMode = "efficiency"
        let tips = Tips.evaluate(inputs { $0.pc = pc; $0.mac?.kind = .other; $0.pcName = String(repeating: "W", count: 40) })
        let report = QualityReport(grade: .poor, rttMs: 40, rttP95Ms: 90, movingSeconds: 60,
                                   hitchesPerMin: .init(mouse: 9, mac: 9, network: 9, pc: 9), tips: tips)
        let size = try JSONEncoder().encode(report).count
        #expect(size + 1 + 16 <= SecureChannel.maxFrame)
    }
}

extension ContractTests {
    private func contract(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/contract/\(name)")
        return try Data(contentsOf: url)
    }

    @Test func pcStatsMatchFixture() throws {
        let stats = try JSONDecoder().decode(PcStats.self, from: contract("pc-stats.json"))
        #expect(stats.moves == 118)
        #expect(stats.hitches == 2)
        #expect(stats.link == "wifi")
        #expect(stats.signalBars == 4)
        #expect(stats.powerMode == "balanced")
        // Older or partial stats decode too.
        #expect(try JSONDecoder().decode(PcStats.self, from: Data("{}".utf8)).moves == 0)
    }

    @Test func qualityReportMatchesFixture() throws {
        let report = try JSONDecoder().decode(QualityReport.self, from: contract("quality-report.json"))
        #expect(report.grade == .fair)
        #expect(report.hitchesPerMin.network == 4.3)
        #expect(report.tips?.first?.status == .act)
        // And what the Mac writes reads back the same.
        let again = try JSONDecoder().decode(QualityReport.self, from: JSONEncoder().encode(report))
        #expect(again == report)
    }
}

extension QualityTests {
    @Test func roundTripsRightAfterConnectingAreSkipped() {
        let monitor = QualityMonitor()
        monitor.connected(pc, at: start)
        monitor.addRTT(pc, ms: 80, at: start.addingTimeInterval(1))
        monitor.addRTT(pc, ms: 4, at: start.addingTimeInterval(4))
        #expect(monitor.history(pc).rtt.map(\.ms) == [4])
    }
}
