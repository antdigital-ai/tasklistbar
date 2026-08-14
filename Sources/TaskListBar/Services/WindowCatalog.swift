import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

struct CatalogWindow: Identifiable, Hashable, Sendable {
    var id: CGWindowID { windowID }
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool
    let isMinimized: Bool

    func displayTitle(index: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "窗口 \(index + 1)"
    }
}

@MainActor
final class WindowCatalog: ObservableObject {
    @Published private(set) var windows: [CatalogWindow] = []
    @Published private(set) var uiPIDs: Set<pid_t> = []
    @Published private(set) var badges: [String: Int] = [:]
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var unresponsivePIDs: Set<pid_t> = []
    @Published private(set) var frontmostWindowID: CGWindowID?

    private var pollTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var pendingScan = false
    private var lastSignature = ""
    private var hungCache: [pid_t: (value: Bool, at: Date)] = [:]
    private var hungCursor = 0

    func start() {
        stop()
        scheduleScan()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.scheduleScan()
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        scanTask?.cancel()
        scanTask = nil
        pendingScan = false
    }

    func refresh() {
        scheduleScan()
    }

    func windows(for bundleID: String) -> [CatalogWindow] {
        windows.filter { $0.bundleID == bundleID }
    }

    private func scheduleScan() {
        if scanTask != nil {
            pendingScan = true
            return
        }
        let hungCache = self.hungCache
        let hungCursor = self.hungCursor
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = WindowCatalog.scanSnapshot()
            let extras = WindowCatalog.readDockExtras()
            let hung = WindowCatalog.probeUnresponsive(
                pids: snapshot.uiPIDs,
                cache: hungCache,
                cursor: hungCursor
            )
            guard let self else { return }
            await MainActor.run {
                self.apply(snapshot, extras: extras, hung: hung)
                self.scanTask = nil
                if self.pendingScan {
                    self.pendingScan = false
                    self.scheduleScan()
                }
            }
        }
    }

    private func apply(_ snapshot: Snapshot, extras: DockExtras, hung: HungResult) {
        hungCache = hung.cache
        hungCursor = hung.cursor
        let signature = snapshot.signature
            + "|b:\(extras.badges.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
            + "|p:\(extras.progress.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value * 100))" }.joined(separator: ","))"
            + "|h:\(hung.pids.sorted().map(String.init).joined(separator: ","))"

        guard signature != lastSignature else { return }
        lastSignature = signature
        windows = snapshot.windows
        uiPIDs = snapshot.uiPIDs
        frontmostWindowID = snapshot.frontmostWindowID
        badges = extras.badges
        progress = extras.progress
        unresponsivePIDs = hung.pids
    }

    private struct Snapshot: Sendable {
        var windows: [CatalogWindow]
        var uiPIDs: Set<pid_t>
        var frontmostWindowID: CGWindowID?

        var signature: String {
            let windowPart = windows
                .map { "\($0.bundleID)#\($0.windowID):\($0.title):\($0.isMinimized ? 1 : 0):\($0.isOnScreen ? 1 : 0)" }
                .joined(separator: "|")
            let pidPart = uiPIDs.sorted().map(String.init).joined(separator: ",")
            return "\(windowPart)<\(pidPart)><\(frontmostWindowID ?? 0)>"
        }
    }

    nonisolated private static func scanSnapshot() -> Snapshot {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return Snapshot(windows: [], uiPIDs: [], frontmostWindowID: nil)
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var pidBundles: [pid_t: String] = [:]
        var windows: [CatalogWindow] = []
        var uiPIDs = Set<pid_t>()
        var frontmostWindowID: CGWindowID?
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let bounds = cgBounds(info[kCGWindowBounds as String] as? [String: Any])
            let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let tooSmall = bounds.width < 50 || bounds.height < 50
            if tooSmall { continue }
            if onScreen, alpha <= 0.05 { continue }

            uiPIDs.insert(pid)

            let bundleID: String
            if let cached = pidBundles[pid] {
                bundleID = cached
            } else if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                pidBundles[pid] = bid
                bundleID = bid
            } else {
                continue
            }
            if bundleID == AppItemFactory.ownBundleID { continue }

            let windowID = CGWindowID((info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else { continue }

            let title = (info[kCGWindowName as String] as? String) ?? ""
            if isLikelyDesktopWindow(bundleID: bundleID, title: title, bounds: bounds) { continue }

            let minimized = !onScreen
            windows.append(
                CatalogWindow(
                    windowID: windowID,
                    pid: pid,
                    bundleID: bundleID,
                    title: title,
                    bounds: bounds,
                    isOnScreen: onScreen,
                    isMinimized: minimized
                )
            )

            if frontmostWindowID == nil, onScreen, pid == frontPID {
                frontmostWindowID = windowID
            }
        }

        return Snapshot(windows: windows, uiPIDs: uiPIDs, frontmostWindowID: frontmostWindowID)
    }

    nonisolated private static func isLikelyDesktopWindow(bundleID: String, title: String, bounds: CGRect) -> Bool {
        guard bundleID == "com.apple.finder" else { return false }
        let lower = title.lowercased()
        if lower == "desktop" || title == "桌面" { return true }
        guard title.isEmpty else { return false }
        return NSScreen.screens.contains {
            abs($0.frame.width - bounds.width) < 4 && abs($0.frame.height - bounds.height) < 4
        }
    }

    nonisolated private static func cgBounds(_ raw: [String: Any]?) -> CGRect {
        guard let raw else { return .zero }
        return CGRect(
            x: cgFloatValue(raw["X"]),
            y: cgFloatValue(raw["Y"]),
            width: cgFloatValue(raw["Width"]),
            height: cgFloatValue(raw["Height"])
        )
    }

    nonisolated private static func cgFloatValue(_ raw: Any?) -> CGFloat {
        if let number = raw as? NSNumber { return CGFloat(truncating: number) }
        if let value = raw as? CGFloat { return value }
        if let value = raw as? Double { return CGFloat(value) }
        return 0
    }

    private struct DockExtras: Sendable {
        var badges: [String: Int]
        var progress: [String: Double]
    }

    private struct HungResult: Sendable {
        var pids: Set<pid_t>
        var cache: [pid_t: (value: Bool, at: Date)]
        var cursor: Int
    }

    nonisolated private static func readDockExtras() -> DockExtras {
        guard AXIsProcessTrusted() else { return DockExtras(badges: [:], progress: [:]) }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return DockExtras(badges: [:], progress: [:]) }

        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var items: [AXUIElement] = []
        collectDockItems(root, into: &items)
        guard !items.isEmpty else { return DockExtras(badges: [:], progress: [:]) }

        var nameToBundle: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, let name = app.localizedName?.lowercased() else { continue }
            nameToBundle[name] = bid
        }

        var badges: [String: Int] = [:]
        var progress: [String: Double] = [:]
        for item in items {
            let title = (AXHelper.string(item, kAXTitleAttribute as CFString) ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let bid = nameToBundle[title.lowercased()]
                ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == title }?.bundleIdentifier
            guard let bid else { continue }

            let status = AXHelper.string(item, "AXStatusDescription" as CFString)
            let description = AXHelper.string(item, kAXDescriptionAttribute as CFString)
            if let badge = firstInteger(in: status), badge > 0 {
                badges[bid] = badge
            } else if let description,
                      description.localizedCaseInsensitiveContains("unread")
                        || description.contains("未读")
                        || description.contains("封新"),
                      let badge = firstInteger(in: description), badge > 0 {
                badges[bid] = badge
            }
            if let value = AXHelper.number(item, "AXProgressValue" as CFString) {
                let normalized = value > 1 ? value / 100 : value
                if normalized > 0, normalized < 1 {
                    progress[bid] = normalized
                }
            } else if let percent = firstPercent(in: description) ?? firstPercent(in: status) {
                progress[bid] = percent
            }
        }
        return DockExtras(badges: badges, progress: progress)
    }

    nonisolated private static func collectDockItems(_ element: AXUIElement, into result: inout [AXUIElement]) {
        let role = AXHelper.string(element, kAXRoleAttribute as CFString) ?? ""
        if role == (kAXDockItemRole as String) || role == "AXDockItem" {
            result.append(element)
        }
        guard let children = AXHelper.children(element) else { return }
        for child in children {
            collectDockItems(child, into: &result)
        }
    }

    nonisolated private static func firstInteger(in text: String?) -> Int? {
        guard let text, let match = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(text[match])
    }

    nonisolated private static func firstPercent(in text: String?) -> Double? {
        guard let text, let match = text.range(of: #"(\d{1,3})\s*%"#, options: .regularExpression) else { return nil }
        let digits = text[match].filter(\.isNumber)
        guard let value = Double(digits), value <= 100 else { return nil }
        return value / 100
    }

    nonisolated private static func probeUnresponsive(
        pids: Set<pid_t>,
        cache: [pid_t: (value: Bool, at: Date)],
        cursor: Int
    ) -> HungResult {
        guard AXIsProcessTrusted() else {
            return HungResult(pids: [], cache: [:], cursor: cursor)
        }
        let now = Date()
        var cache = cache.filter { now.timeIntervalSince($0.value.at) < 8 }
        let list = pids.sorted()
        guard !list.isEmpty else {
            return HungResult(pids: [], cache: cache, cursor: cursor)
        }

        var result = Set(cache.compactMap { pids.contains($0.key) && $0.value.value ? $0.key : nil })
        var probed = 0
        var index = list.isEmpty ? 0 : cursor % list.count
        while probed < min(6, list.count) {
            let pid = list[index]
            if let cached = cache[pid], now.timeIntervalSince(cached.at) < 2 {
                if cached.value { result.insert(pid) } else { result.remove(pid) }
            } else {
                let hung = WindowRaiser.isUnresponsive(pid: pid)
                cache[pid] = (hung, now)
                if hung { result.insert(pid) } else { result.remove(pid) }
            }
            probed += 1
            index = (index + 1) % list.count
        }
        return HungResult(pids: result, cache: cache, cursor: index)
    }
}

enum WindowRaiser {
    static func raise(pid: pid_t, windowID: CGWindowID, title: String?) {
        guard let window = findWindow(pid: pid, windowID: windowID, title: title) else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    @discardableResult
    static func minimize(pid: pid_t, windowID: CGWindowID, title: String?) -> Bool {
        guard let window = findWindow(pid: pid, windowID: windowID, title: title) else { return false }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    static func close(pid: pid_t, windowID: CGWindowID, title: String?) {
        guard let window = findWindow(pid: pid, windowID: windowID, title: title) else { return }
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let button = buttonRef
        else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    static func isUnresponsive(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        var ref: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &ref)
        return error == .cannotComplete
    }

    private static func findWindow(pid: pid_t, windowID: CGWindowID, title: String?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = AXHelper.children(app, attribute: kAXWindowsAttribute as CFString) else { return nil }

        for window in windows {
            if let number = AXHelper.number(window, "AXWindowNumber" as CFString),
               CGWindowID(UInt32(number)) == windowID {
                return window
            }
        }
        if let title, !title.isEmpty {
            if let match = windows.first(where: { AXHelper.string($0, kAXTitleAttribute as CFString) == title }) {
                return match
            }
        }
        return windows.first
    }
}

enum AXHelper {
    static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    static func number(_ element: AXUIElement, _ attribute: CFString) -> Double? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        if let number = ref as? NSNumber { return number.doubleValue }
        return nil
    }

    static func children(_ element: AXUIElement, attribute: CFString = kAXChildrenAttribute as CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }
}
