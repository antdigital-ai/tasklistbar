import AppKit
import SwiftUI

struct SystemTrayView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var spaces: SpacesMonitor
    @ObservedObject var trash: TrashMonitor
    @ObservedObject var clock: ClockModel

    var body: some View {
        HStack(spacing: 3) {
            if battery.status.isPresent {
                BatteryTrayButton(status: battery.status)
            }

            SpacesTrayButton(space: spaces.currentSpace, count: spaces.spaceCount) {
                spaces.openMissionControl()
            }

            TrashTrayButton(isEmpty: trash.isEmpty, count: trash.itemCount) {
                trash.openTrash()
            } emptyAction: {
                trash.emptyTrash()
            }

            ClockTrayView(date: clock.now)
        }
        .padding(.trailing, 2)
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
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(status.percentage ?? 100 <= 15 && !status.isCharging ? Color.red.opacity(0.95) : Color.primary.opacity(0.85))
                .frame(width: TaskbarMetrics.trayHit, height: TaskbarMetrics.trayHit)
                .background(
                    RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                        .fill(hovering ? TaskbarTheme.hover : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
    }
}

struct SpacesTrayButton: View {
    let space: Int
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(space)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.9))
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.16) : Color.primary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("桌面 \(space) / \(count)（点击打开调度中心）")
    }
}

struct TrashTrayButton: View {
    let isEmpty: Bool
    let count: Int
    let action: () -> Void
    let emptyAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: isEmpty ? "trash" : "trash.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: TaskbarMetrics.trayHit, height: TaskbarMetrics.trayHit)

                if !isEmpty {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                        .offset(x: 0, y: -1)
                }
            }
            .frame(width: TaskbarMetrics.trayHit, height: TaskbarMetrics.trayHit)
            .background(
                RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                    .fill(hovering ? TaskbarTheme.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isEmpty ? "废纸篓（空）" : "废纸篓（\(count) 项）")
        .contextMenu {
            Button("打开废纸篓", action: action)
            Button("清倒废纸篓", role: .destructive, action: emptyAction)
                .disabled(isEmpty)
        }
    }
}

struct ClockTrayView: View {
    let date: Date

    /// uBar-style: "周三 12, 22:27"
    private var text: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE d, HH:mm"
        return formatter.string(from: date)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.92))
            .padding(.horizontal, 4)
            .help(fullDateHelp)
            .onTapGesture {
                let calendar = URL(fileURLWithPath: "/System/Applications/Calendar.app")
                if FileManager.default.fileExists(atPath: calendar.path) {
                    NSWorkspace.shared.open(calendar)
                }
            }
    }

    private var fullDateHelp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return formatter.string(from: date)
    }
}
