import AppKit
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissionCenter: PermissionCenter
    let onOpenPermissions: () -> Void
    let onOpenModifierKeys: () -> Void
    let onClose: () -> Void

    enum Metrics {
        static let width: CGFloat = 380
        static let height: CGFloat = 588
        static let corner: CGFloat = 14
    }

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var q: SettingsQuery { SettingsQuery(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(height: 0.5)
            content
            if let error = settings.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            searchFocused = true
            permissionCenter.refresh()
        }
        .onDisappear {
            settings.isRecordingHotkey = false
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 16, weight: .semibold))
                Text("任务栏外观、行为与快捷键")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.68))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(PressableScaleButtonStyle())
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.45))
                .frame(width: 16, alignment: .center)
            TextField("搜索设置", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var content: some View {
        let appearance = appearanceFlags
        let behavior = behaviorFlags
        let shortcuts = shortcutFlags
        let permissions = q.row("权限", "辅助功能", "屏幕录制", "日历", "位置", "蓝牙", "磁盘", "accessibility", "permission", in: "权限")
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if permissions {
                    settingsSection("权限") {
                        SettingsLinkRow(
                            title: "系统权限",
                            detail: permissionCenter.hasRequired
                                ? (permissionCenter.missingCount == 0 ? "已全部开启" : "还可开启 \(permissionCenter.missingCount) 项")
                                : "还差\(permissionCenter.missingRequiredTitle)"
                        ) {
                            onOpenPermissions()
                        }
                    }
                }

                if appearance.hasVisible {
                    settingsSection("外观") {
                        row(appearance.theme, divider: false) {
                            SettingsSegmentedRow(
                                title: "主题",
                                items: Array(AppAppearance.allCases),
                                titleFor: \.title,
                                selected: { settings.appearance == $0 }
                            ) { settings.setAppearance($0) }
                        }
                        row(appearance.size, divider: appearance.theme) {
                            SettingsSegmentedRow(
                                title: "大小",
                                items: Array(TaskbarSize.allCases),
                                titleFor: \.title,
                                selected: { settings.barSize == $0 }
                            ) { settings.setBarSize($0) }
                        }
                        row(appearance.grouping, divider: appearance.theme || appearance.size) {
                            SettingsSegmentedRow(
                                title: "分组",
                                items: Array(WindowGrouping.allCases),
                                titleFor: \.title,
                                selected: { settings.windowGrouping == $0 }
                            ) { settings.setWindowGrouping($0) }
                        }
                        row(appearance.accent, divider: appearance.theme || appearance.size || appearance.grouping) {
                            SettingsAccentRow(
                                selected: settings.accent,
                                onSelect: { settings.setAccent($0) }
                            )
                        }
                    }
                }

                if behavior.hasVisible {
                    settingsSection("行为") {
                        row(behavior.launchAtLogin, divider: false) {
                            SettingsToggleRow(
                                title: "开机时启动",
                                subtitle: "登录后自动打开 KeelBar",
                                isOn: Binding(
                                    get: { settings.launchAtLogin },
                                    set: { settings.setLaunchAtLogin($0) }
                                )
                            )
                        }
                        row(behavior.hideDock, divider: behavior.launchAtLogin) {
                            SettingsToggleRow(
                                title: "隐藏系统 Dock",
                                subtitle: "用任务栏替代系统程序坞",
                                isOn: Binding(
                                    get: { settings.hideDock },
                                    set: { settings.setHideDock($0) }
                                )
                            )
                        }
                        row(behavior.avoidWindows, divider: behavior.launchAtLogin || behavior.hideDock) {
                            SettingsToggleRow(
                                title: "最大化时避开底栏",
                                subtitle: "浏览器和窗口会让出底栏高度",
                                isOn: Binding(
                                    get: { settings.avoidOverlappingWindows },
                                    set: { settings.setAvoidOverlappingWindows($0) }
                                )
                            )
                        }
                        row(behavior.badges, divider: behavior.launchAtLogin || behavior.hideDock || behavior.avoidWindows) {
                            SettingsToggleRow(
                                title: "显示角标",
                                subtitle: "未读数与进度会显示在图标上",
                                isOn: Binding(
                                    get: { settings.showBadges },
                                    set: { settings.setShowBadges($0) }
                                )
                            )
                        }
                        row(behavior.desktop, divider: behavior.launchAtLogin || behavior.hideDock || behavior.avoidWindows || behavior.badges) {
                            SettingsToggleRow(
                                title: "收藏桌面",
                                isOn: Binding(
                                    get: { settings.showDesktopFavorite },
                                    set: { settings.setShowDesktopFavorite($0) }
                                )
                            )
                        }
                        row(behavior.trash, divider: behavior.launchAtLogin || behavior.hideDock || behavior.avoidWindows || behavior.badges || behavior.desktop) {
                            SettingsToggleRow(
                                title: "收藏废纸篓",
                                isOn: Binding(
                                    get: { settings.showTrashFavorite },
                                    set: { settings.setShowTrashFavorite($0) }
                                )
                            )
                        }
                    }
                }

                if shortcuts.hasVisible {
                    settingsSection("快捷键") {
                        row(shortcuts.startMenu, divider: false) {
                            HotkeyRecorderRow(
                                title: "开始菜单",
                                chord: settings.startMenuHotkey,
                                isBlocked: settings.isRecordingHotkey,
                                onRecord: { settings.isRecordingHotkey = $0 },
                                onSet: { settings.setStartMenuHotkey($0) }
                            )
                        }
                        row(shortcuts.calendar, divider: shortcuts.startMenu) {
                            HotkeyRecorderRow(
                                title: "日历",
                                chord: settings.calendarHotkey,
                                isBlocked: settings.isRecordingHotkey,
                                onRecord: { settings.isRecordingHotkey = $0 },
                                onSet: { settings.setCalendarHotkey($0) }
                            )
                        }
                        row(shortcuts.modifiers, divider: shortcuts.startMenu || shortcuts.calendar) {
                            SettingsLinkRow(title: "修饰键", detail: "外置键盘映射") {
                                onOpenModifierKeys()
                            }
                        }
                        row(shortcuts.logs, divider: shortcuts.startMenu || shortcuts.calendar || shortcuts.modifiers) {
                            SettingsLinkRow(title: "打开日志", detail: nil) {
                                AppLog.openInFinder()
                            }
                        }
                    }
                }

                if !permissions && !appearance.hasVisible && !behavior.hasVisible && !shortcuts.hasVisible {
                    Text("没有匹配的设置")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var appearanceFlags: (
        theme: Bool, size: Bool, grouping: Bool, accent: Bool, hasVisible: Bool
    ) {
        let theme = q.row("主题", "跟随系统", "浅色", "深色", "外观", "theme", "light", "dark", "system", in: "外观")
        let size = q.row("大小", "小", "中", "大", "特大", "尺寸", "size", "compact", "large", in: "外观")
        let grouping = q.row("分组", "自动", "总是", "从不", "合并", "窗口", "group", "grouping", in: "外观")
        let accent = q.row("强调色", "颜色", "蓝", "紫", "粉", "红", "橙", "黄", "绿", "灰", "accent", "color", in: "外观")
        return (theme, size, grouping, accent, theme || size || grouping || accent)
    }

    private var behaviorFlags: (
        launchAtLogin: Bool, hideDock: Bool, avoidWindows: Bool, badges: Bool, desktop: Bool, trash: Bool, hasVisible: Bool
    ) {
        let launchAtLogin = q.row("开机时启动", "登录", "自启", "启动", "login", "launch", in: "行为")
        let hideDock = q.row("隐藏系统 Dock", "程序坞", "dock", "隐藏", in: "行为")
        let avoidWindows = q.row("最大化时避开底栏", "避开", "最大化", "重叠", "窗口", "avoid", in: "行为")
        let badges = q.row("显示角标", "未读", "进度", "badge", in: "行为")
        let desktop = q.row("收藏桌面", "桌面", "desktop", in: "行为")
        let trash = q.row("收藏废纸篓", "废纸篓", "回收站", "trash", in: "行为")
        return (launchAtLogin, hideDock, avoidWindows, badges, desktop, trash, launchAtLogin || hideDock || avoidWindows || badges || desktop || trash)
    }

    private var shortcutFlags: (
        startMenu: Bool, calendar: Bool, modifiers: Bool, logs: Bool, hasVisible: Bool
    ) {
        let startMenu = q.row("开始菜单", "热键", "快捷键", "hotkey", "start", in: "快捷键")
        let calendar = q.row("日历", "热键", "快捷键", "calendar", "hotkey", in: "快捷键")
        let modifiers = q.row("修饰键", "外置键盘", "映射", "Control", "Command", "键盘", "modifier", in: "快捷键")
        let logs = q.row("打开日志", "日志", "log", in: "快捷键")
        return (startMenu, calendar, modifiers, logs, startMenu || calendar || modifiers || logs)
    }

    @ViewBuilder
    private func row<Content: View>(_ visible: Bool, divider: Bool, @ViewBuilder content: () -> Content) -> some View {
        if visible {
            if divider { SettingsRowDivider() }
            content()
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.42))
                .padding(.horizontal, 4)
            SettingsCard(content: content)
        }
    }
}

private struct SettingsQuery {
    let needle: String

    init(_ raw: String) {
        needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func matches(_ keys: [String]) -> Bool {
        guard !needle.isEmpty else { return true }
        return keys.contains { $0.lowercased().contains(needle) }
    }

    func row(_ keys: String..., in section: String) -> Bool {
        matches([section] + keys)
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: AppSettingsView.Metrics.corner, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppSettingsView.Metrics.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

private struct SettingsSegmentedRow<Item: Identifiable>: View {
    let title: String
    let items: [Item]
    let titleFor: (Item) -> String
    let selected: (Item) -> Bool
    let action: (Item) -> Void
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 46, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(items) { item in
                    let isSelected = selected(item)
                    Button {
                        action(item)
                    } label: {
                        Text(titleFor(item))
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? accent.onAccent : .primary.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? accent.color : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }
}

private struct SettingsAccentRow: View {
    let selected: AppAccent
    let onSelect: (AppAccent) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("强调色")
                .font(.system(size: 13))
                .frame(width: 46, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(AppAccent.allCases) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(item.color)
                                .frame(width: 16, height: 16)
                            Circle()
                                .strokeBorder(
                                    Color.primary.opacity(selected == item ? 0.28 : 0.08),
                                    lineWidth: selected == item ? 1.5 : 0.5
                                )
                                .frame(width: 20, height: 20)
                            if selected == item {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(item.onAccent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.primary.opacity(0.42))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(accent.color)
        .padding(.horizontal, 12)
        .padding(.vertical, subtitle == nil ? 6 : 8)
        .frame(minHeight: subtitle == nil ? 34 : 44)
    }
}

private struct SettingsLinkRow: View {
    let title: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.28))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .foregroundStyle(isRecording ? accent.onAccent : .primary.opacity(0.62))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isRecording ? accent.color : Color.primary.opacity(0.08))
                    )
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
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
