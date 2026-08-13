import AppKit
import SwiftUI

struct SystemTrayView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var spaces: SpacesMonitor
    @ObservedObject var bluetooth: BluetoothMonitor
    @ObservedObject var volume: VolumeMonitor
    @ObservedObject var clock: ClockModel
    var isCalendarOpen: Bool = false
    var onToggleCalendar: (() -> Void)?
    @Environment(\.taskbarSize) private var size

    var body: some View {
        HStack(spacing: 3) {
            if battery.status.isPresent {
                BatteryTrayButton(status: battery.status)
            }

            SpacesTrayButton(space: spaces.currentSpace, count: spaces.spaceCount) {
                spaces.openMissionControl()
            }

            BluetoothTrayButton(bluetooth: bluetooth)
            VolumeTrayButton(volume: volume)

            ClockTrayView(
                text: clock.trayText,
                helpText: clock.helpText(),
                isOpen: isCalendarOpen,
                onToggle: { onToggleCalendar?() }
            )
        }
        .frame(height: size.trayHit)
        .padding(.trailing, 2)
    }
}

struct BatteryTrayButton: View {
    let status: BatteryMonitor.Status
    @Environment(\.taskbarSize) private var size
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
            Image(systemName: symbolName)
                .font(.system(size: size.traySymbol, weight: .medium))
                .foregroundStyle(status.percentage ?? 100 <= 15 && !status.isCharging ? Color.red.opacity(0.95) : Color.primary.opacity(0.85))
                .frame(width: size.trayHit, height: size.trayHit)
                .background(
                    RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                        .fill(hovering ? TaskbarTheme.hover : Color.clear)
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

struct SpacesTrayButton: View {
    let space: Int
    let count: Int
    let action: () -> Void
    @Environment(\.taskbarSize) private var size
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(space)")
                .font(.system(size: size.trayFont, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.9))
                .frame(minWidth: size.trayHit - 4, minHeight: size.trayHit - 4)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.16) : Color.primary.opacity(0.10))
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
    @Environment(\.taskbarSize) private var size
    @State private var hovering = false
    @State private var showingFlyout = false

    private var helpText: String {
        if !bluetooth.isPoweredOn { return "蓝牙已关闭" }
        return "蓝牙已开启 · \(bluetooth.connectedNames)"
    }

    var body: some View {
        Button {
            showingFlyout.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: BluetoothTrayIcon.image(isOn: bluetooth.isPoweredOn))
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.traySymbol + 3, height: size.traySymbol + 3)
                    .foregroundStyle(bluetooth.isPoweredOn ? Color.primary.opacity(0.92) : Color.primary.opacity(0.38))

                if bluetooth.isPoweredOn, bluetooth.connectedCount > 0 {
                    Circle()
                        .fill(Color.green.opacity(0.95))
                        .frame(width: max(4, size.traySymbol * 0.38), height: max(4, size.traySymbol * 0.38))
                        .offset(x: 5, y: -4)
                }
            }
            .frame(width: size.trayHit, height: size.trayHit)
            .background(
                RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                    .fill(showingFlyout || hovering ? TaskbarTheme.hover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: size.corner, style: .continuous))
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

/// Bluetooth bind-rune (Hagall + Bjarkan). On is a solid mark; off is the
/// same rune with an SF-style slash cut through it.
private enum BluetoothTrayIcon {
    private static var onImage: NSImage?
    private static var offImage: NSImage?

    static func image(isOn: Bool) -> NSImage {
        if isOn {
            if let onImage { return onImage }
            let image = draw(isOn: true)
            onImage = image
            return image
        }
        if let offImage { return offImage }
        let image = draw(isOn: false)
        offImage = image
        return image
    }

    private static func draw(isOn: Bool) -> NSImage {
        let side: CGFloat = 16
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            context.shouldAntialias = true
            drawRune(in: NSRect(x: 0, y: 0, width: side, height: side), isOn: isOn)
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    private static func drawRune(in rect: NSRect, isOn: Bool) {
        let cx = rect.midX + rect.width * 0.02
        let cy = rect.midY
        let s = min(rect.width, rect.height) * 0.88

        func pt(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint {
            NSPoint(x: cx + dx * s, y: cy + dy * s)
        }

        let top = pt(0, 0.46)
        let mid = pt(0, 0)
        let bottom = pt(0, -0.46)
        let upperRight = pt(0.36, 0.23)
        let lowerRight = pt(0.36, -0.23)
        let upperLeft = pt(-0.30, 0.23)
        let lowerLeft = pt(-0.30, -0.23)

        let rune = NSBezierPath()
        rune.lineCapStyle = .round
        rune.lineJoinStyle = .round
        rune.lineWidth = isOn ? rect.width * 0.12 : rect.width * 0.09

        rune.move(to: top)
        rune.line(to: bottom)

        rune.move(to: top)
        rune.line(to: upperRight)
        rune.line(to: mid)

        rune.move(to: bottom)
        rune.line(to: lowerRight)
        rune.line(to: mid)

        rune.move(to: upperLeft)
        rune.line(to: mid)
        rune.move(to: lowerLeft)
        rune.line(to: mid)

        NSColor.black.setStroke()
        rune.stroke()

        guard !isOn, let context = NSGraphicsContext.current else { return }

        let slashStart = pt(-0.42, -0.40)
        let slashEnd = pt(0.42, 0.40)

        context.compositingOperation = .destinationOut
        let cut = NSBezierPath()
        cut.lineCapStyle = .round
        cut.lineWidth = rect.width * 0.18
        cut.move(to: slashStart)
        cut.line(to: slashEnd)
        cut.stroke()

        context.compositingOperation = .sourceOver
        let slash = NSBezierPath()
        slash.lineCapStyle = .round
        slash.lineWidth = rect.width * 0.09
        slash.move(to: slashStart)
        slash.line(to: slashEnd)
        slash.stroke()
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
    }
}

struct VolumeTrayButton: View {
    @ObservedObject var volume: VolumeMonitor
    @Environment(\.taskbarSize) private var size
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
            Image(systemName: symbolName)
                .font(.system(size: size.traySymbol, weight: .medium))
                .foregroundStyle(volume.isMuted ? Color.primary.opacity(0.45) : Color.primary.opacity(0.85))
                .frame(width: size.trayHit, height: size.trayHit)
                .background(
                    RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                        .fill(showingFlyout || hovering ? TaskbarTheme.hover : Color.clear)
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
                    RoundedRectangle(cornerRadius: size.corner, style: .continuous)
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

private final class FirstMouseSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
