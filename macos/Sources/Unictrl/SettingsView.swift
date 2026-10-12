import SwiftUI

/// Unictrl Settings on one page, most used first: the screens, the PCs, then options.
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var removing: AppController.Device?
    /// The screen being renamed ("mac" or a PC's ID) and the text in the field.
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                if controller.devices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "display").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("No PCs yet").font(.headline)
                        Button("Pair a Windows PC…") { controller.startPairing() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ScreensCanvas(tiles: controller.tiles, arrangement: controller.arrangement,
                                  activeID: controller.remoteID ?? Arrangement.mac) { controller.setArrangement($0) }
                        .frame(height: 240)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Screens")
                    Spacer()
                    Text("Drag any screen to match your desk").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.pineGradient)
                        Image(systemName: "macbook").font(.system(size: 13)).foregroundStyle(.white)
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(controller.macName)
                        Text("This Mac").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    renameButton(Arrangement.mac, current: controller.macName)
                }
                ForEach(controller.devices) { device in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(device.online ? AnyShapeStyle(Color.pineGradient) : AnyShapeStyle(.quaternary))
                            Image(systemName: "display").font(.system(size: 13)).foregroundStyle(device.online ? .white : .secondary)
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                            Text(detail(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusLabel(device: device, inUse: controller.remoteID == device.id, quality: controller.quality)
                        Menu("Position") {
                            Button("Windows above Mac") { controller.placePeer(device.id, on: .top) }
                            Button("Windows below Mac") { controller.placePeer(device.id, on: .bottom) }
                            Button("Windows left of Mac") { controller.placePeer(device.id, on: .left) }
                            Button("Windows right of Mac") { controller.placePeer(device.id, on: .right) }
                        }.fixedSize()
                        renameButton(device.id, current: device.name)
                        Button { removing = device } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(device.name)")
                    }
                }
                Button { controller.startPairing() } label: {
                    Label("Pair a Windows PC…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Devices")
            }

            QualitySection(quality: controller.quality, devices: controller.devices)

            Section("General") {
                Toggle("Share this Mac’s keyboard and mouse", isOn: $controller.enabled)
                Picker(selection: $controller.shareChannel) {
                    Text("Any channel").tag(-1)
                    ForEach(0..<3) { Text("Channel \($0 + 1)").tag($0) }
                } label: {
                    Text("Share on Easy-Switch")
                    Text(controller.channelAllowsSharing
                         ? "Shares only while the keyboard is on this channel; on others each computer keeps its own."
                         : controller.statusLine + ".")
                }
                if controller.shareChannel >= 0 {
                    Toggle("Play a sound when keyboard and mouse are both on channel \(controller.shareChannel + 1)",
                           isOn: $controller.readySound)
                    if controller.readySound {
                        Picker("Sound", selection: $controller.readySoundName) {
                            ForEach(controller.systemSounds, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Toggle("Open at login", isOn: $controller.startAtLogin)
                Toggle("Show in menu bar", isOn: $controller.showMenuBarIcon)
                Toggle(isOn: $controller.showDockIcon) {
                    Text("Show in Dock")
                    Text("With both icons off, open Unictrl again from Spotlight or Launchpad to see Settings.")
                }
                Toggle(isOn: $controller.sleepHandoff) {
                    Text("Move keyboard and mouse to a PC when this Mac sleeps")
                    Text(controller.easySwitchNote)
                }
                Picker("Pointer on PCs", selection: $controller.pointerMode) {
                    Text("Use each PC’s settings").tag("native")
                    Text("Match this Mac").tag("physical")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $controller.pcPointerScale, in: 0.5...1.5, step: 0.05)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                        Text("\(Int((controller.pcPointerScale * 100).rounded())) %")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                    .frame(width: 280)
                } label: {
                    Text("Pointer speed on PCs")
                    Text("Lower it if the pointer feels loose when you move fast.")
                }
                if controller.accessibilityGranted && controller.inputMonitoringGranted {
                    LabeledContent("Permissions") {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    PermissionRow(title: "Accessibility", detail: "Moves the pointer between computers",
                                  granted: controller.accessibilityGranted) { controller.requestAccessibility() }
                    PermissionRow(title: "Input Monitoring", detail: "Reads the MX Keys special keys",
                                  granted: controller.inputMonitoringGranted) { controller.requestInputMonitoring() }
                }
            }

            Section {
                Toggle(isOn: $controller.reverseMouseWheel) {
                    Text("Reverse mouse wheel")
                    Text("Wheel mice only; trackpads keep natural scrolling. Also applies on your PCs.")
                }
                Toggle("Smooth scrolling", isOn: $controller.smoothScrolling)
                LabeledContent("Scroll speed on this Mac") {
                    speedSlider($controller.scrollScale)
                }
                LabeledContent {
                    speedSlider($controller.pcScrollScale)
                } label: {
                    Text("Scroll speed on PCs")
                    Text("On top of the PC’s own lines-per-notch setting.")
                }
            } header: {
                Text("Mouse wheel")
            } footer: {
                Text("© 2026 Enliva LLC")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.top, 16)
            }

        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 771, maxWidth: .infinity, minHeight: 420, idealHeight: 776, maxHeight: .infinity)
        .tint(.pine)
        .alert("Rename", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map { controller.defaultName(of: $0) } ?? "", text: $newName)
            Button("Rename") {
                if let id = renaming { controller.rename(id, to: newName) }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Shown on the Mac and on every PC. Leave empty for the computer’s own name.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this PC")?", isPresented: .init(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { device in
            Button("Remove", role: .destructive) { controller.removePeer(device.id) }
        } message: { _ in
            Text("The PC is disconnected and its key is deleted. To use it again, pair it again.")
        }
    }

    private func speedSlider(_ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
            Slider(value: value, in: 0.5...2, step: 0.1)
            Image(systemName: "hare").foregroundStyle(.secondary)
            Text("\(Int((value.wrappedValue * 100).rounded())) %")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
        .frame(width: 280)
    }

    private func renameButton(_ id: String, current: String) -> some View {
        Button {
            newName = current
            renaming = id
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Rename \(current)")
    }

    private func detail(_ device: AppController.Device) -> String {
        let size = controller.screenSize(of: device.id)
        return String(format: "%.0f × %.0f cm screen", size.width / 10, size.height / 10)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
