import AppKit
import Combine
import Foundation

enum WindowGrouping: String, CaseIterable, Identifiable {
    case automatic
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .always: return "总是"
        case .never: return "从不"
        }
    }

    var subtitle: String {
        switch self {
        case .automatic: return "栏上放得下就每个窗口一格"
        case .always: return "同一应用合并为一格"
        case .never: return "每个窗口一格"
        }
    }
}

enum AppSettingKey {
    static let launchAtLogin = "launchAtLogin"
    static let hideSystemDock = "hideSystemDock"
    static let appearance = "appAppearance"
    static let accent = "appAccent"
    static let barSize = "taskbarSize"
    static let startMenuHotkey = "startMenuHotkey"
    static let calendarHotkey = "calendarHotkey"
    static let avoidOverlappingWindows = "avoidOverlappingWindows"
    static let calendarExpanded = "calendarExpanded"
    static let windowGrouping = "windowGrouping"
    static let showWindowCount = "showWindowCount"
    static let showBadges = "showBadges"
    static let showDesktopFavorite = "showDesktopFavorite"
    static let showTrashFavorite = "showTrashFavorite"
}

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var hideDock: Bool
    @Published private(set) var appearance: AppAppearance
    @Published private(set) var accent: AppAccent
    @Published private(set) var barSize: TaskbarSize
    @Published private(set) var startMenuHotkey: HotkeyChord?
    @Published private(set) var calendarHotkey: HotkeyChord?
    @Published private(set) var avoidOverlappingWindows: Bool
    @Published private(set) var calendarExpanded: Bool
    @Published private(set) var windowGrouping: WindowGrouping
    @Published private(set) var showWindowCount: Bool
    @Published private(set) var showBadges: Bool
    @Published private(set) var showDesktopFavorite: Bool
    @Published private(set) var showTrashFavorite: Bool
    @Published var isRecordingHotkey = false
    @Published private(set) var lastError: String?

    init() {
        let defaults = UserDefaults.standard
        launchAtLogin = defaults.bool(forKey: AppSettingKey.launchAtLogin) || LoginItemService.isEnabled
        hideDock = defaults.bool(forKey: AppSettingKey.hideSystemDock)
        appearance = AppAppearance(rawValue: defaults.string(forKey: AppSettingKey.appearance) ?? "") ?? .system
        accent = AppAccent(rawValue: defaults.string(forKey: AppSettingKey.accent) ?? "") ?? .blue
        barSize = TaskbarSize(rawValue: defaults.string(forKey: AppSettingKey.barSize) ?? "") ?? .regular
        startMenuHotkey = Self.loadHotkey(key: AppSettingKey.startMenuHotkey, fallback: .startMenuDefault)
        calendarHotkey = Self.loadHotkey(key: AppSettingKey.calendarHotkey, fallback: .calendarDefault)
        if defaults.object(forKey: AppSettingKey.avoidOverlappingWindows) == nil {
            avoidOverlappingWindows = true
        } else {
            avoidOverlappingWindows = defaults.bool(forKey: AppSettingKey.avoidOverlappingWindows)
        }
        if defaults.object(forKey: AppSettingKey.calendarExpanded) == nil {
            calendarExpanded = true
        } else {
            calendarExpanded = defaults.bool(forKey: AppSettingKey.calendarExpanded)
        }
        windowGrouping = WindowGrouping(rawValue: defaults.string(forKey: AppSettingKey.windowGrouping) ?? "") ?? .automatic
        showWindowCount = defaults.object(forKey: AppSettingKey.showWindowCount) as? Bool ?? true
        showBadges = defaults.object(forKey: AppSettingKey.showBadges) as? Bool ?? true
        showDesktopFavorite = defaults.object(forKey: AppSettingKey.showDesktopFavorite) as? Bool ?? true
        showTrashFavorite = defaults.object(forKey: AppSettingKey.showTrashFavorite) as? Bool ?? true
        defaults.set(launchAtLogin, forKey: AppSettingKey.launchAtLogin)
        TaskbarMetrics.size = barSize
    }

    func applyOnLaunch() {
        TaskbarMetrics.size = barSize
        applyAppearance()
        if hideDock {
            DockHider.hide()
        }
        if launchAtLogin, !LoginItemService.isEnabled {
            try? LoginItemService.setEnabled(true)
        }
    }

    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: AppSettingKey.appearance)
        applyAppearance()
    }

    func setAccent(_ accent: AppAccent) {
        self.accent = accent
        UserDefaults.standard.set(accent.rawValue, forKey: AppSettingKey.accent)
    }

    func setBarSize(_ size: TaskbarSize) {
        barSize = size
        TaskbarMetrics.size = size
        UserDefaults.standard.set(size.rawValue, forKey: AppSettingKey.barSize)
    }

    func applyAppearance() {
        let nsAppearance = appearance.nsAppearance
        NSApp.appearance = nsAppearance
        for window in NSApp.windows {
            window.appearance = nsAppearance
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        lastError = nil
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtLogin = enabled
            UserDefaults.standard.set(enabled, forKey: AppSettingKey.launchAtLogin)
            if enabled && LoginItemService.needsApproval {
                lastError = "请在「系统设置 → 通用 → 登录项」中允许 KeelBar。"
                LoginItemService.openLoginItemsSettings()
            }
        } catch {
            launchAtLogin = LoginItemService.isEnabled
            UserDefaults.standard.set(launchAtLogin, forKey: AppSettingKey.launchAtLogin)
            lastError = error.localizedDescription
        }
    }

    func setHideDock(_ enabled: Bool) {
        lastError = nil
        hideDock = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingKey.hideSystemDock)
        if enabled {
            DockHider.hide()
        } else {
            DockHider.restore()
        }
    }

    func setAvoidOverlappingWindows(_ enabled: Bool) {
        lastError = nil
        avoidOverlappingWindows = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingKey.avoidOverlappingWindows)
    }

    func setCalendarExpanded(_ expanded: Bool) {
        calendarExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: AppSettingKey.calendarExpanded)
    }

    func setWindowGrouping(_ grouping: WindowGrouping) {
        windowGrouping = grouping
        UserDefaults.standard.set(grouping.rawValue, forKey: AppSettingKey.windowGrouping)
    }

    func setShowWindowCount(_ enabled: Bool) {
        showWindowCount = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingKey.showWindowCount)
    }

    func setShowBadges(_ enabled: Bool) {
        showBadges = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingKey.showBadges)
    }

    func setShowDesktopFavorite(_ enabled: Bool) {
        showDesktopFavorite = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingKey.showDesktopFavorite)
    }

    func setShowTrashFavorite(_ enabled: Bool) {
        showTrashFavorite = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingKey.showTrashFavorite)
    }

    func setStartMenuHotkey(_ chord: HotkeyChord?) {
        lastError = nil
        if let chord, chord == calendarHotkey {
            lastError = "与「日历」快捷键冲突，请换一组按键。"
            return
        }
        startMenuHotkey = chord
        Self.saveHotkey(chord, key: AppSettingKey.startMenuHotkey)
    }

    func setCalendarHotkey(_ chord: HotkeyChord?) {
        lastError = nil
        if let chord, chord == startMenuHotkey {
            lastError = "与「开始菜单」快捷键冲突，请换一组按键。"
            return
        }
        calendarHotkey = chord
        Self.saveHotkey(chord, key: AppSettingKey.calendarHotkey)
    }

    private static func loadHotkey(key: String, fallback: HotkeyChord) -> HotkeyChord? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return fallback }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(HotkeyChord.self, from: data)) ?? fallback
    }

    private static func saveHotkey(_ chord: HotkeyChord?, key: String) {
        if let chord, let data = try? JSONEncoder().encode(chord) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.set(Data(), forKey: key)
        }
    }
}
