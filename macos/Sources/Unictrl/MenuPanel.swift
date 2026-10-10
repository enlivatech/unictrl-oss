import SwiftUI

/// The menu bar panel, laid out like Control Center: status and master switch, the screens,
/// the paired PCs, the two scrolling switches as tiles, then actions.
struct MenuPanel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !controller.accessibilityGranted {
                PermissionCallout(title: "Accessibility is off",
                                  detail: "Needed to move the pointer to your PCs.") { controller.requestAccessibility() }
            } else if !controller.inputMonitoringGranted {
                PermissionCallout(title: "Input Monitoring is off",
                                  detail: "Needed for the MX Keys special keys.") { controller.requestInputMonitoring() }
            }
            if !controller.devices.isEmpty {
                Button { controller.showSettings() } label: {
                    ScreensCanvas(tiles: controller.tiles, arrangement: controller.arrangement,
                                  activeID: controller.remoteID ?? Arrangement.mac, compact: true)
                        .frame(height: 64)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help("Arrange screens")
                devices
            }
            HStack(spacing: 8) {
                ToggleTile(title: "Reverse Wheel", systemImage: "arrow.up.arrow.down", isOn: $controller.reverseMouseWheel)
                ToggleTile(title: "Smooth Scroll", systemImage: "scroll", isOn: $controller.smoothScrolling)
            }
            Divider().padding(.horizontal, 4)
            VStack(spacing: 0) {
                PanelRow(title: "Pair a Windows PC…", systemImage: "plus.circle") { controller.startPairing() }
                PanelRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") { controller.showSettings() }
                PanelRow(title: "Quit Unictrl", systemImage: "power", shortcut: "⌘Q") { controller.quit() }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(controller.enabled ? AnyShapeStyle(Color.pineGradient) : AnyShapeStyle(.quaternary))
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(controller.enabled ? .white : .secondary)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unictrl").font(.system(size: 13, weight: .semibold))
                Text(controller.enabled ? controller.statusLine : "Paused")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("Enabled", isOn: $controller.enabled)
                .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(.pine)
        }
        .padding(.horizontal, 4)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Devices").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.bottom, 2)
            ForEach(controller.devices) { device in
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(device.online ? AnyShapeStyle(Color.pine.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.6)))
                        Image(systemName: "display").font(.system(size: 12))
                            .foregroundStyle(device.online ? Color.pine : Color.secondary)
                    }
                    .frame(width: 26, height: 26)
                    Text(device.name).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    StatusLabel(device: device, inUse: controller.remoteID == device.id, quality: controller.quality)
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
            }
        }
    }
}

struct StatusLabel: View {
    let device: AppController.Device
    let inUse: Bool
    @ObservedObject var quality: QualityMonitor

    var body: some View {
        let grade = quality.reports[device.id]?.grade
        HStack(spacing: 5) {
            Circle().fill(!device.online ? Color.secondary.opacity(0.5) : grade == .fair ? .orange : grade == .poor ? .red : .green)
                .frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(device.online ? "Connection: \((grade ?? .idle).label)" : "Offline")
    }

    private var text: String {
        guard device.online else { return "Offline" }
        if inUse { return "In use" }
        return device.latencyMs.map { "\($0) ms" } ?? "Connected"
    }
}

/// A Control Center style switch: a round icon that fills with colour when on.
private struct ToggleTile: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(isOn ? AnyShapeStyle(Color.pine) : AnyShapeStyle(.quaternary))
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(isOn ? "On" : "Off").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(hovering ? 0.9 : 0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A menu-like row that highlights under the pointer.
private struct PanelRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(hovering ? Color.white : Color.secondary)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary) }
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PermissionCallout: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Allow…", action: action).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}
