import AppKit
import SwiftUI

enum TaskbarSize: String, CaseIterable, Identifiable {
    case compact
    case regular
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "小"
        case .regular: return "中"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }

    var subtitle: String {
        switch self {
        case .compact: return "28pt 底栏"
        case .regular: return "36pt 底栏"
        case .large: return "48pt 底栏"
        case .extraLarge: return "64pt 底栏"
        }
    }

    var barHeight: CGFloat {
        switch self {
        case .compact: return 28
        case .regular: return 36
        case .large: return 48
        case .extraLarge: return 64
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: return 16
        case .regular: return 20
        case .large: return 28
        case .extraLarge: return 40
        }
    }

    var appButtonWidth: CGFloat {
        switch self {
        case .compact: return 26
        case .regular: return 32
        case .large: return 42
        case .extraLarge: return 56
        }
    }

    var appButtonHeight: CGFloat {
        switch self {
        case .compact: return 22
        case .regular: return 28
        case .large: return 40
        case .extraLarge: return 54
        }
    }

    var avatarSize: CGFloat {
        switch self {
        case .compact: return 16
        case .regular: return 22
        case .large: return 30
        case .extraLarge: return 40
        }
    }

    var trayHit: CGFloat {
        switch self {
        case .compact: return 18
        case .regular: return 22
        case .large: return 30
        case .extraLarge: return 40
        }
    }

    var traySymbol: CGFloat {
        switch self {
        case .compact: return 10
        case .regular: return 12
        case .large: return 14
        case .extraLarge: return 17
        }
    }

    var trayFont: CGFloat {
        switch self {
        case .compact: return 10
        case .regular: return 11
        case .large: return 12
        case .extraLarge: return 14
        }
    }

    var indicatorHeight: CGFloat {
        switch self {
        case .compact: return 2
        case .regular: return 2
        case .large: return 2.5
        case .extraLarge: return 3
        }
    }

    var indicatorActiveWidth: CGFloat {
        switch self {
        case .compact: return 11
        case .regular: return 14
        case .large: return 16
        case .extraLarge: return 20
        }
    }

    var indicatorRunningWidth: CGFloat {
        switch self {
        case .compact: return 5
        case .regular: return 6
        case .large: return 7
        case .extraLarge: return 8
        }
    }

    var corner: CGFloat {
        switch self {
        case .compact: return 6
        case .regular: return 8
        case .large: return 10
        case .extraLarge: return 12
        }
    }

    var dividerHeight: CGFloat {
        switch self {
        case .compact: return 14
        case .regular: return 18
        case .large: return 24
        case .extraLarge: return 32
        }
    }

    var badgeFont: CGFloat {
        switch self {
        case .compact: return 7
        case .regular: return 8
        case .large: return 9
        case .extraLarge: return 11
        }
    }

    var avatarInitials: CGFloat {
        switch self {
        case .compact: return 8
        case .regular: return 9
        case .large: return 11
        case .extraLarge: return 14
        }
    }

    var previewBarHeight: CGFloat {
        switch self {
        case .compact: return 5
        case .regular: return 8
        case .large: return 12
        case .extraLarge: return 16
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "与 macOS 外观一致"
        case .light: return "浅色毛玻璃"
        case .dark: return "深色毛玻璃"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "蓝"
        case .purple: return "紫"
        case .pink: return "粉"
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .graphite: return "灰"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .purple: return Color(red: 0.56, green: 0.32, blue: 0.90)
        case .pink: return Color(red: 0.90, green: 0.30, blue: 0.55)
        case .red: return Color(red: 0.90, green: 0.30, blue: 0.28)
        case .orange: return Color(red: 0.95, green: 0.52, blue: 0.18)
        case .yellow: return Color(red: 0.95, green: 0.76, blue: 0.18)
        case .green: return Color(red: 0.22, green: 0.70, blue: 0.42)
        case .graphite: return Color(red: 0.48, green: 0.52, blue: 0.56)
        }
    }

    var onAccent: Color {
        self == .yellow ? Color.black.opacity(0.82) : Color.white
    }
}

private struct TaskbarAccentKey: EnvironmentKey {
    static let defaultValue = AppAccent.blue
}

private struct TaskbarSizeKey: EnvironmentKey {
    static let defaultValue = TaskbarSize.regular
}

extension EnvironmentValues {
    var taskbarAccent: AppAccent {
        get { self[TaskbarAccentKey.self] }
        set { self[TaskbarAccentKey.self] = newValue }
    }

    var taskbarSize: TaskbarSize {
        get { self[TaskbarSizeKey.self] }
        set { self[TaskbarSizeKey.self] = newValue }
    }
}

struct ThemedRoot<Content: View>: View {
    @ObservedObject var settings: AppSettings
    let content: Content

    init(settings: AppSettings, @ViewBuilder content: () -> Content) {
        self.settings = settings
        self.content = content()
    }

    var body: some View {
        content
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.taskbarAccent, settings.accent)
            .environment(\.taskbarSize, settings.barSize)
            .environmentObject(settings)
            .background(Color.clear)
            .animation(TaskbarMotion.hover, value: settings.appearance)
            .animation(TaskbarMotion.hover, value: settings.accent)
            .animation(TaskbarMotion.sizeChange, value: settings.barSize)
    }
}
