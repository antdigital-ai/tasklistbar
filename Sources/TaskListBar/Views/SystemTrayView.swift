import AppKit
import SwiftUI

struct SystemTrayView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var boost: BoostService
    @ObservedObject var spaces: SpacesMonitor
    @ObservedObject var bluetooth: BluetoothMonitor
    @ObservedObject var volume: VolumeMonitor
    @ObservedObject var clock: ClockModel
    var isCalendarOpen: Bool = false
    var onToggleCalendar: (() -> Void)?
    var onShowDesktop: (() -> Void)?
    @Environment(\.taskbarSize) private var size

    var body: some View {
        HStack(spacing: 1) {
            if battery.status.isPresent {
                BatteryTrayButton(status: battery.status)
            }

            BoostTrayButton(boost: boost)

            SpacesTrayButton(space: spaces.currentSpace, count: spaces.spaceCount) {
                spaces.openMissionControl()
            }

            BluetoothTrayButton(bluetooth: bluetooth)
            VolumeTrayButton(volume: volume)

            ClockTrayView(
                text: clock.trayText,
                helpText: clock.helpText,
                isOpen: isCalendarOpen,
                onToggle: { onToggleCalendar?() }
            )

            ShowDesktopTrayButton(action: { onShowDesktop?() })
        }
        .frame(height: size.trayHit)
        .padding(.trailing, 1)
    }
}

/// Shared macOS-style chrome for every compact tray symbol. SF Symbols handles
/// optical sizing; the fixed hit target keeps baselines and hover shapes aligned.
private struct TraySymbol: View {
    let name: String
    var color: Color = .primary.opacity(0.86)
    var isHighlighted = false
    var weight: Font.Weight = .regular

    @Environment(\.taskbarSize) private var size

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size.traySymbol, weight: weight))
            .foregroundStyle(color)
            .frame(width: size.trayHit, height: size.trayHit)
            .background(
                RoundedRectangle(cornerRadius: size.trayHit * 0.28, style: .continuous)
                    .fill(isHighlighted ? TaskbarTheme.hover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: size.trayHit * 0.28, style: .continuous))
    }
}

/// Bluetooth is a native menu-extra glyph rather than a public SF Symbol.
/// Reuse Apple's template image so its geometry matches the macOS menu bar.
private struct TrayBluetoothSymbol: View {
    var isPoweredOn: Bool
    var isHighlighted: Bool

    @Environment(\.taskbarSize) private var size

    private static let systemImage: NSImage = {
        NSImage(named: NSImage.Name("NSBluetoothTemplate"))
            ?? NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "蓝牙")
            ?? NSImage()
    }()

    var body: some View {
        ZStack {
            Image(nsImage: Self.systemImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.traySymbol * 0.78, height: size.traySymbol * 1.06)

            if !isPoweredOn {
                Image(systemName: "slash")
                    .font(.system(size: size.traySymbol * 1.08, weight: .medium))
            }
        }
        .foregroundStyle(Color.primary.opacity(isPoweredOn ? 0.88 : 0.38))
        .frame(width: size.trayHit, height: size.trayHit)
        .background(
            RoundedRectangle(cornerRadius: size.trayHit * 0.28, style: .continuous)
                .fill(isHighlighted ? TaskbarTheme.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: size.trayHit * 0.28, style: .continuous))
    }
}

struct BatteryTrayButton: View {
    let status: BatteryMonitor.Status
    @State private var hovering = false

    private var helpText: String {
        var parts: [String] = []
        if let percentage = status.percentage {
            parts.append("\(percentage)%")
        }
        if status.isCharging {
            parts.append("充电中")
        } else if status.isPluggedIn {
            parts.append("电源已连接")
        } else {
            parts.append("使用电池")
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        let pct = status.percentage ?? 100
        if status.isCharging {
            return "battery.100.bolt"
        }
        switch pct {
        case 0..<15: return "battery.0"
        case 15..<40: return "battery.25"
        case 40..<70: return "battery.50"
        case 70..<95: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            TraySymbol(
                name: symbolName,
                color: status.percentage ?? 100 <= 15 && !status.isCharging
                    ? Color.red.opacity(0.92)
                    : Color.primary.opacity(0.84),
                isHighlighted: hovering
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(helpText)
    }
}

struct BoostTrayButton: View {
    @ObservedObject var boost: BoostService
    @Environment(\.taskbarAccent) private var accent
    @State private var hovering = false
    @State private var showingFlyout = false
    @State private var justCleaned = false
    @State private var cleanFlashTask: Task<Void, Never>?

    private var helpText: String {
        if boost.pressure.isHigh {
            return "AI 占用偏高 · CPU \(boost.pressure.cpuPercent)% · 内存 \(boost.pressure.rssMB)MB（点击清理）"
        }
        return "加速：关闭编译 / AI 进程，并清理 Worktree 与 Node 依赖"
    }

    private var iconColor: Color {
        if justCleaned { return accent.color }
        if boost.pressure.isHigh { return Color(red: 0.96, green: 0.78, blue: 0.18) }
        return Color.primary.opacity(hovering ? 0.98 : 0.88)
    }

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showingFlyout.toggle()
        } label: {
            TraySymbol(
                name: boost.pressure.isHigh ? "bolt.fill" : "bolt",
                color: iconColor,
                isHighlighted: showingFlyout || hovering,
                weight: .medium
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(helpText)
        .popover(isPresented: $showingFlyout, arrowEdge: .top) {
            BoostFlyout(boost: boost) {
                showingFlyout = false
            }
        }
        .onChange(of: boost.snapshot.generation) { _ in
            guard boost.snapshot.generation > 0 else { return }
            flashCleaned()
        }
    }

    private func flashCleaned() {
        cleanFlashTask?.cancel()
        justCleaned = true
        cleanFlashTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            justCleaned = false
        }
    }
}

struct BoostFlyout: View {
    @ObservedObject var boost: BoostService
    let onClose: () -> Void
    @Environment(\.taskbarAccent) private var accent
    @State private var groups: [BoostService.ProcessGroup] = []
    @State private var disks: [BoostService.DiskItem] = []
    @State private var selected: Set<String> = []
    @State private var didScan = false
    @State private var didScanDisk = false

    private var selectedCount: Int {
        groups.filter { selected.contains($0.label) }.reduce(0) { $0 + $1.count }
    }

    private var selectedBytes: Int64 {
        let chosen = disks.filter { selected.contains($0.id) }
        let worktreePaths = chosen
            .filter { $0.kind != .nodeDependencies }
            .flatMap { $0.entries.map(\.url.path) }
        var total: Int64 = 0
        for item in chosen {
            if item.kind == .nodeDependencies {
                for entry in item.entries where !worktreePaths.contains(where: { entry.url.path.hasPrefix($0 + "/") }) {
                    total += entry.bytes
                }
            } else {
                total += item.bytes
            }
        }
        return total
    }

    private var canClean: Bool {
        !boost.isRunning && (
            selectedCount > 0 || disks.contains { selected.contains($0.id) }
        )
    }

    private var listHeight: CGFloat {
        let processBlock: CGFloat = groups.isEmpty ? 0 : 22 + CGFloat(groups.count) * 30
        let diskBlock: CGFloat
        if !disks.isEmpty {
            diskBlock = 22 + CGFloat(disks.count) * 38
        } else if !didScanDisk {
            diskBlock = 28
        } else {
            diskBlock = 0
        }
        let spacing: CGFloat = (processBlock > 0 && diskBlock > 0) ? 14 : 0
        return min(560, max(420, processBlock + diskBlock + spacing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("加速清理")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    reload(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
                .help("重新扫描")
            }

            if !didScan {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("扫描中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else if groups.isEmpty && disks.isEmpty && didScanDisk {
                Text("没有发现可清理的进程或文件")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !groups.isEmpty {
                            flyoutSection("进程") {
                                ForEach(groups) { group in
                                    cleanupRow(
                                        title: group.label,
                                        accessory: "\(group.count)",
                                        isOn: binding(for: group.label)
                                    )
                                }
                            }
                        }
                        if !disks.isEmpty {
                            flyoutSection("磁盘") {
                                ForEach(disks) { item in
                                    cleanupRow(
                                        title: item.label,
                                        subtitle: item.detail,
                                        accessory: BoostService.formatBytes(item.bytes),
                                        isOn: binding(for: item.id)
                                    )
                                }
                            }
                        } else if !didScanDisk {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在计算磁盘占用…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(height: listHeight, alignment: .top)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    if selectedCount > 0 {
                        Text("\(selectedCount) 个进程")
                    }
                    if selectedBytes > 0 {
                        Text("可回收 \(BoostService.formatBytes(selectedBytes))")
                    }
                    if selectedCount == 0 && selectedBytes == 0 {
                        Text("未选择")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    let chosenGroups = groups.filter { selected.contains($0.label) }
                    let chosenDisks = disks.filter { selected.contains($0.id) }
                    boost.boost(groups: chosenGroups, disks: chosenDisks)
                    onClose()
                } label: {
                    Text("清理选中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(accent.color.opacity(canClean ? 1 : 0.4))
                        )
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.94))
                .disabled(!canClean)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .top)
        .background(PopoverKeyGrabber())
        .onAppear { reload(force: false) }
    }

    private func flyoutSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.42))
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
        }
    }

    private func cleanupRow(title: String, subtitle: String? = nil, accessory: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(accessory)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func binding(for label: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(label) },
            set: { on in
                if on {
                    selected.insert(label)
                } else {
                    selected.remove(label)
                }
            }
        )
    }

    private func reload(force: Bool = false) {
        let hasProcessCache = !boost.lastGroups.isEmpty
        let hasDiskCache = boost.disksCached
        if force || !hasProcessCache {
            didScan = false
        }
        if force || !hasDiskCache {
            didScanDisk = false
            if force { disks = [] }
        } else {
            disks = boost.lastDisks
            didScanDisk = true
        }
        if hasProcessCache && !force {
            groups = boost.lastGroups
            selected = Set(groups.map(\.label) + disks.filter(\.selectedByDefault).map(\.id))
            didScan = true
        }
        Task { @MainActor in
            async let processScan = boost.scan(force: force)
            async let diskScan = boost.scanDisk(force: force)
            let processResult = await processScan
            groups = processResult
            selected = Set(processResult.map(\.label))
            didScan = true
            let diskResult = await diskScan
            disks = diskResult
            selected.formUnion(diskResult.filter(\.selectedByDefault).map(\.id))
            didScanDisk = true
        }
    }
}

struct SpacesTrayButton: View {
    let space: Int
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TraySymbol(
                name: "\(max(0, min(space, 50))).square",
                color: Color.primary.opacity(0.86),
                isHighlighted: hovering,
                weight: .medium
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help("桌面 \(space) / \(count)（点击打开调度中心）")
    }
}

struct BluetoothTrayButton: View {
    @ObservedObject var bluetooth: BluetoothMonitor
    @State private var hovering = false
    @State private var showingFlyout = false

    private var helpText: String {
        if !bluetooth.isPoweredOn { return "蓝牙已关闭" }
        return "蓝牙已开启 · \(bluetooth.connectedNames)"
    }

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showingFlyout.toggle()
        } label: {
            TrayBluetoothSymbol(
                isPoweredOn: bluetooth.isPoweredOn,
                isHighlighted: showingFlyout || hovering
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(helpText)
        .popover(isPresented: $showingFlyout, arrowEdge: .top) {
            BluetoothFlyout(bluetooth: bluetooth)
        }
        .contextMenu {
            Button(bluetooth.isPoweredOn ? "关闭蓝牙" : "打开蓝牙") {
                bluetooth.togglePower()
            }
            Button("蓝牙设置", action: bluetooth.openBluetoothSettings)
        }
    }
}

struct BluetoothFlyout: View {
    @ObservedObject var bluetooth: BluetoothMonitor
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("蓝牙")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Toggle("蓝牙", isOn: Binding(
                    get: { bluetooth.isPoweredOn },
                    set: { bluetooth.setPoweredOn($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(accent.color)
                SettingsIconButton(help: "蓝牙设置", action: bluetooth.openBluetoothSettings)
            }

            if bluetooth.isPoweredOn {
                if bluetooth.devices.isEmpty {
                    Text("没有已配对设备")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(bluetooth.devices) { device in
                            Button {
                                bluetooth.toggleDevice(device)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: device.isConnected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(device.isConnected ? accent.color : Color.primary.opacity(0.35))
                                    Text(device.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(device.isConnected ? "已连接" : "连接")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

        }
        .padding(12)
        .frame(width: 240)
        .background(PopoverKeyGrabber())
    }
}

struct VolumeTrayButton: View {
    @ObservedObject var volume: VolumeMonitor
    @State private var hovering = false
    @State private var showingFlyout = false
    @State private var scrollMonitor: Any?

    private var symbolName: String {
        if volume.isMuted || volume.level < 0.01 { return "speaker.slash.fill" }
        switch volume.level {
        case 0..<0.34: return "speaker.wave.1.fill"
        case 0.34..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            showingFlyout.toggle()
        } label: {
            TraySymbol(
                name: symbolName,
                color: volume.isMuted ? Color.primary.opacity(0.38) : Color.primary.opacity(0.84),
                isHighlighted: showingFlyout || hovering
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
            updateScrollMonitor(hovering)
        }
        .help("\(volume.outputName) · \(volume.isMuted ? "已静音" : "\(volume.percent)%")")
        .popover(isPresented: $showingFlyout, arrowEdge: .top) {
            VolumeFlyout(volume: volume)
        }
        .contextMenu {
            Button(volume.isMuted ? "取消静音" : "静音", action: volume.toggleMute)
            Button("声音设置", action: volume.openSoundSettings)
        }
        .onDisappear { updateScrollMonitor(false) }
    }

    private func updateScrollMonitor(_ hovering: Bool) {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard hovering else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            guard abs(delta) > 0.2 else { return event }
            volume.adjust(by: delta > 0 ? 0.05 : -0.05)
            return nil
        }
    }
}

struct VolumeFlyout: View {
    @ObservedObject var volume: VolumeMonitor
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(volume.outputName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsIconButton(help: "声音设置", action: volume.openSoundSettings)
            }

            HStack(spacing: 8) {
                Button(action: volume.toggleMute) {
                    Image(systemName: volume.isMuted || volume.level < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
                .help(volume.isMuted ? "取消静音" : "静音")

                VolumeSlider(
                    value: Binding(
                        get: { volume.isMuted ? 0 : volume.level },
                        set: { volume.setLevel($0) }
                    ),
                    tint: NSColor(accent.color)
                )

                Text("\(volume.percent)%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(PopoverKeyGrabber(preferSlider: true))
    }
}

struct ClockTrayView: View {
    let text: String
    let helpText: String
    var isOpen: Bool = false
    var onToggle: (() -> Void)?

    @Environment(\.taskbarSize) private var size
    @State private var hovering = false

    var body: some View {
        Button {
            onToggle?()
        } label: {
            Text(text)
                .font(.system(size: size.trayFont, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: size.trayHit)
                .background(
                    RoundedRectangle(cornerRadius: size.trayHit * 0.28, style: .continuous)
                        .fill(isOpen || hovering ? TaskbarTheme.hover : Color.clear)
                )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96))
        .frame(height: size.trayHit)
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(helpText)
    }
}

struct ShowDesktopTrayButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            TraySymbol(
                name: "macwindow",
                color: Color.primary.opacity(0.62),
                isHighlighted: hovering
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help("显示桌面")
    }
}

private struct SettingsIconButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// AppKit slider so dragging works from the non-key taskbar popover.
private struct VolumeSlider: NSViewRepresentable {
    var value: Binding<Double>
    var tint: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(value: value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = FirstMouseSlider()
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value.wrappedValue
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.trackFillColor = tint
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = value
        if abs(slider.doubleValue - value.wrappedValue) > 0.004 {
            slider.doubleValue = value.wrappedValue
        }
        slider.trackFillColor = tint
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

/// Makes a SwiftUI popover the key window so it is selected as soon as it opens.
private struct PopoverKeyGrabber: NSViewRepresentable {
    var preferSlider = false

    func makeNSView(context: Context) -> KeyGrabberView {
        let view = KeyGrabberView()
        view.preferSlider = preferSlider
        return view
    }

    func updateNSView(_ view: KeyGrabberView, context: Context) {
        view.preferSlider = preferSlider
    }
}

private final class KeyGrabberView: NSView {
    var preferSlider = false
    private var didGrab = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            didGrab = false
            return
        }
        grabKey()
    }

    private func grabKey() {
        guard let window, !didGrab else { return }
        didGrab = true
        DispatchQueue.main.async { [weak self] in
            self?.makePopoverKey(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let window = self.window else { return }
            self.makePopoverKey(window)
        }
    }

    private func makePopoverKey(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if let panel = window as? NSPanel {
            panel.becomesKeyOnlyIfNeeded = false
        }
        window.makeKeyAndOrderFront(nil)
        if preferSlider, let slider = Self.firstSlider(in: window.contentView) {
            window.makeFirstResponder(slider)
        }
    }

    private static func firstSlider(in view: NSView?) -> NSSlider? {
        guard let view else { return nil }
        if let slider = view as? NSSlider { return slider }
        for subview in view.subviews {
            if let slider = firstSlider(in: subview) { return slider }
        }
        return nil
    }
}

private final class FirstMouseSlider: NSSlider {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
