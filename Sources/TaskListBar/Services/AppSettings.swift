import AppKit
import Combine
import Foundation

enum AppSettingKey {
    static let launchAtLogin = "launchAtLogin"
    static let hideSystemDock = "hideSystemDock"
    static let appearance = "appAppearance"
    static let accent = "appAccent"
    static let startMenuHotkey = "startMenuHotkey"
    static let calendarHotkey = "calendarHotkey"
    static let avoidOverlappingWindows = "avoidOverlappingWindows"
    static let calendarExpanded = "calendarExpanded"
}

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var hideDock: Bool
    @Published private(set) var appearance: AppAppearance
    @Published private(set) var accent: AppAccent
    @Published private(set) var startMenuHotkey: HotkeyChord?
    @Published private(set) var calendarHotkey: HotkeyChord?
    @Published private(set) var avoidOverlappingWindows: Bool
    @Published private(set) var calendarExpanded: Bool
    @Published var isRecordingHotkey = false
    @Published private(set) var lastError: String?

    init() {
        let defaults = UserDefaults.standard
        launchAtLogin = defaults.bool(forKey: AppSettingKey.launchAtLogin) || LoginItemService.isEnabled
        hideDock = defaults.bool(forKey: AppSettingKey.hideSystemDock)
        appearance = AppAppearance(rawValue: defaults.string(forKey: AppSettingKey.appearance) ?? "") ?? .system
        accent = AppAccent(rawValue: defaults.string(forKey: AppSettingKey.accent) ?? "") ?? .blue
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
        defaults.set(launchAtLogin, forKey: AppSettingKey.launchAtLogin)
    }

    func applyOnLaunch() {
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
                lastError = "请在「系统设置 → 通用 → 登录项」中允许 TaskListBar。"
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
