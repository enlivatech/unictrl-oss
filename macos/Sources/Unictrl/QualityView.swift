import SwiftUI

extension QualityReport.Grade {
    var label: String {
        switch self {
        case .idle: "Waiting for movement"
        case .smooth: "Smooth"
        case .fair: "Some hitches"
        case .poor: "Choppy"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .smooth: .green
        case .fair: .orange
        case .poor: .red
        }
    }
}

extension HitchSource {
    var label: String {
        switch self {
        case .mouse: "Mouse"
        case .mac: "This Mac"
        case .network: "Network"
        case .pc: "PC"
        }
    }

    var color: Color {
        switch self {
        case .mouse: .purple
        case .mac: .blue
        case .network: .orange
        case .pc: .pink
        }
    }
}

/// Settings › Connection: how the pointer is doing on each online PC, live, and what would help.
struct QualitySection: View {
    @ObservedObject var quality: QualityMonitor
    let devices: [AppController.Device]
    /// The breakdown and the checklist stay folded away until asked for.
    @AppStorage("connectionDetailsOpen") private var detailsOpen = false

    var body: some View {
        let online = devices.filter(\.online)
        if !online.isEmpty {
            Section {
                ForEach(online) { device in
                    let report = quality.reports[device.id]
                    QualityCard(quality: quality, device: device, report: report)
                    DisclosureGroup(isExpanded: $detailsOpen) {
                        HitchBreakdown(device: device, report: report)
                        TipsList(tips: report?.tips ?? [])
                    } label: {
                        DetailsLabel(tips: report?.tips ?? [])
                    }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Connection")
                    Spacer()
                    Text("Last minute, live").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct QualityCard: View {
    @ObservedObject var quality: QualityMonitor
    let device: AppController.Device
    let report: QualityReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                let grade = report?.grade ?? .idle
                HStack(spacing: 6) {
                    Circle().fill(grade.color).frame(width: 8, height: 8)
                    Text(grade.label).font(.headline)
                }
                Text(device.name).foregroundStyle(.secondary)
                Spacer()
                if let rtt = report?.rttMs {
                    Text(String(format: "%.0f ms", rtt)).font(.headline).monospacedDigit()
                        .help("Round trip to the PC and back. One way is about half.")
                    if let p95 = report?.rttP95Ms {
                        Text(String(format: "peak %.0f ms", p95)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .help("95 % of round trips in the last minute were this fast or faster.")
                    }
                }
            }
            let history = quality.history(device.id)
            Sparkline(rtt: history.rtt, hitches: history.hitches)
                .frame(height: 48)
                .help("Round trip over the last minute; marks along the bottom are hitches, coloured by where they came from.")
        }
        .padding(.vertical, 4)
    }
}

/// "Details and tips", with how many things are worth doing now.
private struct DetailsLabel: View {
    let tips: [Tip]

    var body: some View {
        let todo = tips.filter { $0.status == .act }.count
        HStack(spacing: 8) {
            Text("Details and tips")
            if todo > 0 {
                Text(todo == 1 ? "1 suggestion" : "\(todo) suggestions")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
        }
    }
}

/// Hitches per minute of movement by where they came from.
private struct HitchBreakdown: View {
    let device: AppController.Device
    let report: QualityReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                ForEach(HitchSource.allCases, id: \.self) { source in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(source.color).frame(width: 3, height: 10)
                        Text(source == .pc ? device.name : source.label).lineLimit(1)
                        Text(rate(source)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                    .help(help(source))
                }
                Spacer(minLength: 0)
            }
            Text((report?.movingSeconds ?? 0) < 3
                 ? "Move the pointer on \(device.name) for a while to measure hitches."
                 : "Hitches per minute of movement, by where they came from.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rate(_ source: HitchSource) -> String {
        guard let report, report.movingSeconds > 0 else { return "–" }
        let value = report.hitchesPerMin[source]
        return value == 0 ? "0" : String(format: "%.1f/min", value)
    }

    private func help(_ source: HitchSource) -> String {
        switch source {
        case .mouse: "Hitches per minute of movement where the mouse’s radio link paused."
        case .mac: "Hitches where this Mac handed mouse events to Unictrl late because it was busy."
        case .network: "Hitches where moves reached the PC late: Wi‑Fi, the router, or either computer’s network."
        case .pc: "Hitches where \(device.name) took long to apply a move."
        }
    }
}

/// Round trips as a line, hitches as ticks along the bottom, the last minute left to right.
private struct Sparkline: View {
    let rtt: [QualityMonitor.Sample]
    let hitches: [QualityMonitor.Hitch]

    var body: some View {
        Canvas { context, size in
            let now = Date()
            let window = QualityMonitor.window
            let tickHeight: CGFloat = 8
            // A gutter on the left for the scale, so its label never sits on the line.
            let gutter: CGFloat = 38
            let plot = CGRect(x: gutter, y: 2, width: size.width - gutter, height: size.height - tickHeight - 6)
            let top = max(20, (rtt.map(\.ms).max() ?? 0) * 1.15)
            func x(_ at: Date) -> CGFloat { plot.maxX - CGFloat(now.timeIntervalSince(at) / window) * plot.width }
            func y(_ ms: Double) -> CGFloat { plot.maxY - CGFloat(min(ms, top) / top) * plot.height }

            // 10 ms guide.
            var guide = Path()
            guide.move(to: CGPoint(x: plot.minX, y: y(10)))
            guide.addLine(to: CGPoint(x: plot.maxX, y: y(10)))
            context.stroke(guide, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            context.draw(Text("10 ms").font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: plot.minX - 6, y: y(10)), anchor: .trailing)

            if rtt.count > 1 {
                var line = Path()
                var area = Path()
                area.move(to: CGPoint(x: x(rtt[0].at), y: plot.maxY))
                for (i, sample) in rtt.enumerated() {
                    let point = CGPoint(x: x(sample.at), y: y(sample.ms))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    area.addLine(to: point)
                }
                area.addLine(to: CGPoint(x: x(rtt[rtt.count - 1].at), y: plot.maxY))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [Color.pine.opacity(0.25), Color.pine.opacity(0.02)]),
                                                         startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                context.stroke(line, with: .color(.pine), lineWidth: 1.2)
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: plot.minX, y: size.height - tickHeight / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - tickHeight / 2))
            context.stroke(baseline, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            for hitch in hitches where x(hitch.at) >= plot.minX {
                let rect = CGRect(x: x(hitch.at) - 1, y: size.height - tickHeight, width: 2, height: tickHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(hitch.source.color))
            }
        }
    }
}

/// The checklist: things to do first, open; what is already fine folded away.
private struct TipsList: View {
    let tips: [Tip]

    var body: some View {
        let todo = tips.filter { $0.status != .ok }
        let fine = tips.filter { $0.status == .ok }
        ForEach(todo) { TipRow(tip: $0) }
        if !fine.isEmpty {
            DisclosureGroup {
                ForEach(fine) { TipRow(tip: $0) }
            } label: {
                Label("\(fine.count) checks passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TipRow: View {
    let tip: Tip
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                TipIcon(status: tip.status).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tip.title).foregroundStyle(.primary)
                    Text(tip.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip.summary)
        .popover(isPresented: $showing, arrowEdge: .trailing) { TipDetail(tip: tip) }
    }
}

private struct TipIcon: View {
    let status: Tip.Status

    var body: some View {
        switch status {
        case .act: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info: Image(systemName: "lightbulb").foregroundStyle(.secondary)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

private struct TipDetail: View {
    let tip: Tip

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TipIcon(status: tip.status)
                Text(tip.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            Text(tip.summary).fixedSize(horizontal: false, vertical: true)
            if let seen = tip.seen {
                Label(seen, systemImage: "gauge.with.dots.needle.33percent")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
            }
            if !(tip.steps.count == 1 && tip.steps[0] == "Nothing to do.") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tip.status == .ok ? "Already done. For reference:" : "How to").font(.subheadline.weight(.semibold))
                    ForEach(Array(tip.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
