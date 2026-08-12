import AppKit
import Foundation

struct TaskbarAppItem: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let url: URL?
    let isRunning: Bool
    let isActive: Bool
    let isPinned: Bool
    let processIdentifier: pid_t?
}

enum AppItemFactory {
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.tasklistbar.app"

    static func make(
        bundleIdentifier: String,
        name: String,
        icon: NSImage?,
        url: URL?,
        isRunning: Bool,
        isActive: Bool,
        isPinned: Bool,
        processIdentifier: pid_t? = nil
    ) -> TaskbarAppItem {
        TaskbarAppItem(
            bundleIdentifier: bundleIdentifier,
            name: name,
            icon: icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: name) ?? NSImage(),
            url: url,
            isRunning: isRunning,
            isActive: isActive,
            isPinned: isPinned,
            processIdentifier: processIdentifier
        )
    }
}
