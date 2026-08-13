import Foundation

/// App Library–style categories, mapped from `LSApplicationCategoryType`.
enum AppCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case productivity
    case utilities
    case social
    case creativity
    case entertainment
    case information
    case health
    case finance
    case lifestyle
    case developer
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productivity: return "效率"
        case .utilities: return "工具"
        case .social: return "社交"
        case .creativity: return "创意"
        case .entertainment: return "娱乐"
        case .information: return "信息与阅读"
        case .health: return "健康与健身"
        case .finance: return "财务"
        case .lifestyle: return "生活"
        case .developer: return "开发者工具"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .productivity: return "briefcase.fill"
        case .utilities: return "wrench.and.screwdriver.fill"
        case .social: return "person.2.fill"
        case .creativity: return "paintbrush.fill"
        case .entertainment: return "gamecontroller.fill"
        case .information: return "book.fill"
        case .health: return "heart.fill"
        case .finance: return "yensign.circle.fill"
        case .lifestyle: return "house.fill"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .other: return "square.grid.2x2.fill"
        }
    }

    /// Stable sort order for App Library–like browsing.
    var sortIndex: Int {
        switch self {
        case .productivity: return 0
        case .utilities: return 1
        case .social: return 2
        case .creativity: return 3
        case .entertainment: return 4
        case .information: return 5
        case .health: return 6
        case .finance: return 7
        case .lifestyle: return 8
        case .developer: return 9
        case .other: return 10
        }
    }

    static func from(lsApplicationCategoryType raw: String?) -> AppCategory {
        guard let raw, !raw.isEmpty else { return .other }
        let key = raw.lowercased()

        if key.contains("developer-tools") { return .developer }
        if key.contains("productivity") || key.contains("business") { return .productivity }
        if key.contains("utilities") { return .utilities }
        if key.contains("social") { return .social }
        if key.contains("graphics") || key.contains("photography") || key.contains("video") {
            return .creativity
        }
        if key.contains("entertainment") || key.contains("games") || key.contains("music") {
            return .entertainment
        }
        if key.contains("news") || key.contains("reference") || key.contains("education") || key.contains("books") {
            return .information
        }
        if key.contains("healthcare") || key.contains("medical") || key.contains("fitness") {
            return .health
        }
        if key.contains("finance") { return .finance }
        if key.contains("lifestyle") || key.contains("travel") || key.contains("sports") || key.contains("weather") || key.contains("food") || key.contains("shopping") {
            return .lifestyle
        }
        return .other
    }

    /// Heuristic fallback when Info.plist has no category.
    static func infer(bundleID: String, name: String) -> AppCategory {
        let text = (bundleID + " " + name).lowercased()
        let rules: [(AppCategory, [String])] = [
            (.developer, ["xcode", "terminal", "iterm", "warp", "docker", "figma", "vscode", "cursor", "git", "simulator", "devtools"]),
            (.social, ["wechat", "qq", "telegram", "slack", "discord", "dingtalk", "feishu", "lark", "zoom", "teams", "mail", "messages"]),
            (.creativity, ["photoshop", "illustrator", "sketch", "pixelmator", "final cut", "logic", "garageband", "keynote", "preview"]),
            (.entertainment, ["music", "tv", "spotify", "netflix", "bilibili", "iqiyi", "steam", "epic", "game"]),
            (.information, ["safari", "chrome", "edge", "firefox", "news", "books", "dictionary", "wikipedia"]),
            (.productivity, ["pages", "numbers", "word", "excel", "notion", "obsidian", "reminders", "calendar", "notes", "todo"]),
            (.utilities, ["finder", "system settings", "system preferences", "activity", "calculator", "archive", "cleaner", "vpn"]),
            (.finance, ["alipay", "wallet", "bank", "pay", "stock", "trading"]),
            (.health, ["fitness", "health", "workout"])
        ]
        for (category, keywords) in rules {
            if keywords.contains(where: { text.contains($0) }) {
                return category
            }
        }
        return .other
    }
}

struct StartMenuCategoryGroup: Identifiable, Hashable {
    var id: String { category.rawValue }
    let category: AppCategory
    let apps: [StartMenuApp]

    var previewApps: [StartMenuApp] {
        Array(apps.prefix(4))
    }
}
