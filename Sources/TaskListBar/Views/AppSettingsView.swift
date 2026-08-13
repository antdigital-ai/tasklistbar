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
            Divider().opacity(0.25)
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            settings.isRecordingHotkey = false
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                Text("开机启动、快捷键、外观、大小与系统 Dock。")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.55))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            appearancePicker
            sizePicker
            accentPicker

            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "开机时启动",
                    subtitle: "登录后自动打开 TaskListBar",
                    systemImage: "power",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
                Divider().opacity(0.18)
                SettingsToggleRow(
                    title: "隐藏系统 Dock",
                    subtitle: "避免挡住底部任务栏；退出后会恢复",
                    systemImage: "menubar.dock.rectangle",
                    isOn: Binding(
                        get: { settings.hideDock },
                        set: { settings.setHideDock($0) }
                    )
                )
                Divider().opacity(0.18)
                SettingsToggleRow(
                    title: "最大化时避开底栏",
                    subtitle: "放大窗口后上移，避免被任务栏挡住",
                    systemImage: "rectangle.bottomhalf.inset.filled",
                    isOn: Binding(
                        get: { settings.avoidOverlappingWindows },
                        set: { settings.setAvoidOverlappingWindows($0) }
                    )
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            hotkeySection

            Button(action: onOpenModifierKeys) {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("修饰键")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.92))
                        Text("为外置键盘调整 Control / Command")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.45))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.35))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.98))

            Text("隐藏 Dock 会打开自动隐藏并拉长唤出延迟。最大化避开底栏需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许 TaskListBar。")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            logSection

            if let error = settings.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷键")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))

            VStack(spacing: 0) {
                HotkeyRecorderRow(
                    title: "开始菜单",
                    subtitle: "在任意应用中打开或关闭",
                    systemImage: "square.grid.2x2",
                    chord: settings.startMenuHotkey,
                    isBlocked: settings.isRecordingHotkey,
                    onRecord: { settings.isRecordingHotkey = $0 },
                    onSet: { settings.setStartMenuHotkey($0) }
                )
                Divider().opacity(0.18)
                HotkeyRecorderRow(
                    title: "日历与天气",
                    subtitle: "打开任务栏右侧预览",
                    systemImage: "calendar",
                    chord: settings.calendarHotkey,
                    isBlocked: settings.isRecordingHotkey,
                    onRecord: { settings.isRecordingHotkey = $0 },
                    onSet: { settings.setCalendarHotkey($0) }
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Text("点右侧组合键后按下新快捷键。Esc 取消，Delete 清除。Esc 也可关闭已打开的面板。")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日志")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))

            HStack(spacing: 8) {
                Button(action: AppLog.openInFinder) {
                    Label("打开日志文件夹", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.98))

                Button(action: AppLog.copyTodayToPasteboard) {
                    Label("复制今天", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.98))
            }
            .foregroundStyle(.primary.opacity(0.85))

            Text("日志保存在「应用程序支持/TaskListBar/logs」，默认保留 7 天。")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("外观")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))
            HStack(spacing: 8) {
                ForEach(AppAppearance.allCases) { appearance in
                    Button {
                        settings.setAppearance(appearance)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: appearance.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                            Text(appearance.title)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(settings.appearance == appearance ? settings.accent.onAccent : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(settings.appearance == appearance ? settings.accent.color.opacity(0.9) : Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96))
                    .help(appearance.subtitle)
                }
            }
        }
    }

    private var sizePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("任务栏大小")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))
            HStack(spacing: 8) {
                ForEach(TaskbarSize.allCases) { size in
                    Button {
                        settings.setBarSize(size)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(settings.barSize == size ? settings.accent.onAccent.opacity(0.92) : Color.primary.opacity(0.35))
                                .frame(width: 22, height: size.previewBarHeight)
                            Text(size.title)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(settings.barSize == size ? settings.accent.onAccent : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(settings.barSize == size ? settings.accent.color.opacity(0.9) : Color.primary.opacity(0.06))
                        )
                    }
                    .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96))
                    .help(size.subtitle)
                }
            }
        }
    }

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("强调色")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))
            HStack(spacing: 10) {
                ForEach(AppAccent.allCases) { accent in
                    Button {
                        settings.setAccent(accent)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(accent.color)
                                .frame(width: 22, height: 22)
                            if settings.accent == accent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(accent.onAccent)
                            }
                        }
                    }
                    .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
                    .help(accent.title)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    private var footer: some View {
        HStack {
            Label("TaskListBar", systemImage: "menubar.dock.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
            Spacer()
            Button(action: onClose) {
                Text("完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accent.color.opacity(0.9))
                    )
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(TaskbarTheme.footerFill)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.92))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                }
            }
        }
        .toggleStyle(.switch)
        .tint(accent.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct HotkeyRecorderRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let chord: HotkeyChord?
    let isBlocked: Bool
    let onRecord: (Bool) -> Void
    let onSet: (HotkeyChord?) -> Void
    @Environment(\.taskbarAccent) private var accent

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: startRecording) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.92))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                Spacer(minLength: 8)
                Text(isRecording ? "按下快捷键" : (chord?.displayString ?? "未设置"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRecording ? accent.onAccent : .primary.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? accent.color.opacity(0.9) : Color.primary.opacity(0.08))
                    )
            }
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.98))
        .disabled(isBlocked && !isRecording)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onDisappear { stopRecording(apply: false) }
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
            stopRecording(apply: false)
            return nil
        }
        if event.keyCode == 51, modifiers.isEmpty {
            onSet(nil)
            stopRecording(apply: false)
            return nil
        }
        guard let chord = HotkeyChord.from(event: event) else { return nil }
        onSet(chord)
        stopRecording(apply: false)
        return nil
    }

    private func stopRecording(apply: Bool) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        onRecord(false)
    }
}
