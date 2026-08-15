import AppKit
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    let onOpenModifierKeys: () -> Void
    let onClose: () -> Void
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.2)
            content
            if let error = settings.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear {
            settings.isRecordingHotkey = false
        }
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsGroup {
                    SettingsChoiceRow(title: "外观") {
                        ForEach(AppAppearance.allCases) { appearance in
                            SettingsSegment(
                                title: appearance.title,
                                selected: settings.appearance == appearance
                            ) {
                                settings.setAppearance(appearance)
                            }
                        }
                    }
                    SettingsChoiceRow(title: "大小") {
                        ForEach(TaskbarSize.allCases) { size in
                            SettingsSegment(
                                title: size.title,
                                selected: settings.barSize == size
                            ) {
                                settings.setBarSize(size)
                            }
                        }
                    }
                    SettingsChoiceRow(title: "分组") {
                        ForEach(WindowGrouping.allCases) { grouping in
                            SettingsSegment(
                                title: grouping.title,
                                selected: settings.windowGrouping == grouping
                            ) {
                                settings.setWindowGrouping(grouping)
                            }
                        }
                    }
                    SettingsChoiceRow(title: "强调色") {
                        ForEach(AppAccent.allCases) { item in
                            Button {
                                settings.setAccent(item)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(item.color)
                                        .frame(width: 14, height: 14)
                                    if settings.accent == item {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundStyle(item.onAccent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help(item.title)
                        }
                    }
                }

                settingsGroup {
                    SettingsToggleRow(
                        title: "开机时启动",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "隐藏系统 Dock",
                        isOn: Binding(
                            get: { settings.hideDock },
                            set: { settings.setHideDock($0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "最大化时避开底栏",
                        isOn: Binding(
                            get: { settings.avoidOverlappingWindows },
                            set: { settings.setAvoidOverlappingWindows($0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "显示角标",
                        isOn: Binding(
                            get: { settings.showBadges },
                            set: { settings.setShowBadges($0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "收藏桌面",
                        isOn: Binding(
                            get: { settings.showDesktopFavorite },
                            set: { settings.setShowDesktopFavorite($0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "收藏废纸篓",
                        isOn: Binding(
                            get: { settings.showTrashFavorite },
                            set: { settings.setShowTrashFavorite($0) }
                        )
                    )
                }

                settingsGroup {
                    HotkeyRecorderRow(
                        title: "开始菜单",
                        chord: settings.startMenuHotkey,
                        isBlocked: settings.isRecordingHotkey,
                        onRecord: { settings.isRecordingHotkey = $0 },
                        onSet: { settings.setStartMenuHotkey($0) }
                    )
                    HotkeyRecorderRow(
                        title: "日历",
                        chord: settings.calendarHotkey,
                        isBlocked: settings.isRecordingHotkey,
                        onRecord: { settings.isRecordingHotkey = $0 },
                        onSet: { settings.setCalendarHotkey($0) }
                    )
                    Button(action: onOpenModifierKeys) {
                        HStack {
                            Text("修饰键")
                                .font(.system(size: 13))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.35))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(action: AppLog.openInFinder) {
                        HStack {
                            Text("打开日志")
                                .font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

private struct SettingsChoiceRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 5) {
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
    }
}

private struct SettingsSegment: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? accent.onAccent : .primary.opacity(0.85))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? accent.color.opacity(0.9) : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent.color)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

private struct HotkeyRecorderRow: View {
    let title: String
    let chord: HotkeyChord?
    let isBlocked: Bool
    let onRecord: (Bool) -> Void
    let onSet: (HotkeyChord?) -> Void
    @Environment(\.taskbarAccent) private var accent

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: startRecording) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                Text(isRecording ? "按下按键" : (chord?.displayString ?? "未设置"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(isRecording ? accent.onAccent : .primary.opacity(0.7))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isRecording ? accent.color.opacity(0.9) : Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBlocked && !isRecording)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecord(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecord(event)
        }
    }

    private func handleRecord(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if event.keyCode == 53, modifiers.isEmpty {
            stopRecording()
            return nil
        }
        if event.keyCode == 51, modifiers.isEmpty {
            onSet(nil)
            stopRecording()
            return nil
        }
        guard let chord = HotkeyChord.from(event: event) else { return nil }
        onSet(chord)
        stopRecording()
        return nil
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        onRecord(false)
    }
}
