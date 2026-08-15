import AppKit
import CoreGraphics
import Foundation

struct TaskbarAppItem: Identifiable, Hashable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let url: URL?
    let isRunning: Bool
    let isActive: Bool
    let isPinned: Bool
    let processIdentifier: pid_t?
    let windowID: CGWindowID?
    let windowIndex: Int?
    let windowTitle: String?
    let windowCount: Int
    let badge: Int?
    let badgeIsUnread: Bool
    let progress: Double?
    let isUnresponsive: Bool
    let isGrouped: Bool
}

enum AppItemFactory {
    static let ownBundleID = Bundle.main.bundleIdentifier ?? AppSupport.bundleID

    static func make(
        bundleIdentifier: String,
        name: String,
        icon: NSImage?,
        url: URL?,
        isRunning: Bool,
        isActive: Bool,
        isPinned: Bool,
        processIdentifier: pid_t? = nil,
        windowID: CGWindowID? = nil,
        windowIndex: Int? = nil,
        windowTitle: String? = nil,
        windowCount: Int = 0,
        badge: Int? = nil,
        badgeIsUnread: Bool = false,
        progress: Double? = nil,
        isUnresponsive: Bool = false,
        isGrouped: Bool = true
    ) -> TaskbarAppItem {
        let id = windowID.map { "\(bundleIdentifier)#\($0)" } ?? bundleIdentifier
        return TaskbarAppItem(
            id: id,
            bundleIdentifier: bundleIdentifier,
            name: name,
            icon: icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: name) ?? NSImage(),
            url: url,
            isRunning: isRunning,
            isActive: isActive,
            isPinned: isPinned,
            processIdentifier: processIdentifier,
            windowID: windowID,
            windowIndex: windowIndex,
            windowTitle: windowTitle,
            windowCount: windowCount,
            badge: badge,
            badgeIsUnread: badgeIsUnread,
            progress: progress,
            isUnresponsive: isUnresponsive,
            isGrouped: isGrouped
        )
    }
}
