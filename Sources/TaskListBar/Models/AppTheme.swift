import AppKit
import SwiftUI

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

extension EnvironmentValues {
    var taskbarAccent: AppAccent {
        get { self[TaskbarAccentKey.self] }
        set { self[TaskbarAccentKey.self] = newValue }
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
            .environmentObject(settings)
            .background(Color.clear)
            .animation(TaskbarMotion.hover, value: settings.appearance)
            .animation(TaskbarMotion.hover, value: settings.accent)
    }
}
