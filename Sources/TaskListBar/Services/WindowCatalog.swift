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
    let axIndex: Int

    func displayTitle(index: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "窗口 \(index + 1)"
    }

    func withTitle(_ title: String) -> CatalogWindow {
        CatalogWindow(
            windowID: windowID,
            pid: pid,
            bundleID: bundleID,
            title: title,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMinimized: isMinimized,
            axIndex: axIndex
        )
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

    /// Faster scans while the window-list popover is open; quieter otherwise.
    var prefersFastPolling = false
    /// Dock AX badge/progress walks are expensive — skip when badges are disabled.
    var includeDockExtras = true

    private var pollTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var pendingScan = false
    private var lastSignature = ""
    private var hungCache: [pid_t: (value: Bool, at: Date)] = [:]
    private var hungCursor = 0
    private var dockExtrasTick = 0
    private var lastDockExtras = DockExtras(badges: [:], progress: [:])

    private var pollIntervalNanoseconds: UInt64 {
        prefersFastPolling ? 750_000_000 : 2_000_000_000
    }

    func start() {
        stop()
        scheduleScan()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let nanos = await MainActor.run { self?.pollIntervalNanoseconds ?? 2_000_000_000 }
                try? await Task.sleep(nanoseconds: nanos)
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
        let shouldReadDock: Bool
        if includeDockExtras {
            dockExtrasTick &+= 1
            // Dock AX tree walk is costly; refresh badges/progress every 3rd scan (~6s idle).
            shouldReadDock = prefersFastPolling || dockExtrasTick % 3 == 1
        } else {
            shouldReadDock = false
            if !lastDockExtras.badges.isEmpty || !lastDockExtras.progress.isEmpty {
                lastDockExtras = DockExtras(badges: [:], progress: [:])
            }
        }
        let reuseExtras = lastDockExtras
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = WindowCatalog.scanSnapshot()
            let extras = shouldReadDock ? WindowCatalog.readDockExtras() : reuseExtras
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
        lastDockExtras = extras
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
        let cg = scanCG()
        let listed = AXIsProcessTrusted() ? scanAXWindows(cg: cg) : cg.onScreenWindows
        return Snapshot(windows: listed, uiPIDs: cg.uiPIDs, frontmostWindowID: cg.frontmostWindowID)
    }

    private struct CGScan: Sendable {
        var onScreenWindows: [CatalogWindow]
        var uiPIDs: Set<pid_t>
        var frontmostWindowID: CGWindowID?
        var bundleByPID: [pid_t: String]
    }

    nonisolated private static func scanCG() -> CGScan {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return CGScan(onScreenWindows: [], uiPIDs: [], frontmostWindowID: nil, bundleByPID: [:])
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var bundleByPID: [pid_t: String] = [:]
        var onScreenWindows: [CatalogWindow] = []
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
            if bounds.width < 50 || bounds.height < 50 { continue }
            if onScreen, alpha <= 0.05 { continue }

            uiPIDs.insert(pid)

            let bundleID: String
            if let cached = bundleByPID[pid] {
                bundleID = cached
            } else if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                bundleByPID[pid] = bid
                bundleID = bid
            } else {
                continue
            }
            if bundleID == AppItemFactory.ownBundleID { continue }

            let windowID = CGWindowID((info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            guard windowID != 0 else { continue }

            let title = (info[kCGWindowName as String] as? String) ?? ""
            if isLikelyDesktopWindow(bundleID: bundleID, title: title, bounds: bounds) { continue }
            if isJunkTitle(title) { continue }

            if onScreen {
                onScreenWindows.append(
                    CatalogWindow(
                        windowID: windowID,
                        pid: pid,
                        bundleID: bundleID,
                        title: title,
                        bounds: bounds,
                        isOnScreen: true,
                        isMinimized: false,
                        axIndex: onScreenWindows.filter { $0.pid == pid }.count
                    )
                )
                if frontmostWindowID == nil, pid == frontPID {
                    frontmostWindowID = windowID
                }
            }
        }

        return CGScan(
            onScreenWindows: onScreenWindows,
            uiPIDs: uiPIDs,
            frontmostWindowID: frontmostWindowID,
            bundleByPID: bundleByPID
        )
    }

    nonisolated private static func scanAXWindows(cg: CGScan) -> [CatalogWindow] {
        var result: [CatalogWindow] = []
        let pids = cg.uiPIDs.sorted()
        for pid in pids {
            guard let bundleID = cg.bundleByPID[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  bundleID != AppItemFactory.ownBundleID
            else { continue }

            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
            guard let axWindows = AXHelper.children(app, attribute: kAXWindowsAttribute as CFString) else { continue }

            var acceptedIndex = 0
            for window in axWindows {
                guard WindowRaiser.isListable(window) else { continue }
                let minimized = AXHelper.bool(window, kAXMinimizedAttribute as CFString) ?? false
                let size = AXHelper.size(window, kAXSizeAttribute as CFString) ?? .zero
                let title = (AXHelper.string(window, kAXTitleAttribute as CFString) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isLikelyDesktopWindow(bundleID: bundleID, title: title, bounds: CGRect(origin: .zero, size: size)) {
                    continue
                }

                let number = AXHelper.number(window, "AXWindowNumber" as CFString).map { CGWindowID(UInt32($0)) }
                let windowID = number
                    ?? cg.onScreenWindows.first { $0.pid == pid && !$0.title.isEmpty && $0.title == title }?.windowID
                    ?? 0

                result.append(
                    CatalogWindow(
                        windowID: windowID,
                        pid: pid,
                        bundleID: bundleID,
                        title: title,
                        bounds: CGRect(origin: .zero, size: size),
                        isOnScreen: !minimized,
                        isMinimized: minimized,
                        axIndex: acceptedIndex
                    )
                )
                acceptedIndex += 1
            }
        }

        let axPIDs = Set(result.map(\.pid))
        for window in cg.onScreenWindows where !axPIDs.contains(window.pid) {
            result.append(window)
        }
        return result
    }

    fileprivate nonisolated static let skippedSubroles: Set<String> = [
        "AXUnknown", "AXOverlay", "AXImage", "AXToolbar"
    ]

    fileprivate nonisolated static func isJunkTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower == "focus proxy"
            || lower == "msitemoverlay"
            || lower == "chrome legacy window"
            || lower.hasPrefix("item-")
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
    static func raise(pid: pid_t, windowID: CGWindowID, title: String?, axIndex: Int? = nil) {
        guard let window = findWindow(pid: pid, windowID: windowID, title: title, axIndex: axIndex) else { return }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    @discardableResult
    static func minimize(pid: pid_t, windowID: CGWindowID, title: String?, axIndex: Int? = nil) -> Bool {
        guard let window = findWindow(pid: pid, windowID: windowID, title: title, axIndex: axIndex) else { return false }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    static func close(pid: pid_t, windowID: CGWindowID, title: String?, axIndex: Int? = nil) {
        guard let window = findWindow(pid: pid, windowID: windowID, title: title, axIndex: axIndex) else { return }
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

    struct WindowInfo {
        var number: CGWindowID?
        var title: String
    }

    static func windowInfos(pid: pid_t) -> [WindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let windows = AXHelper.children(app, attribute: kAXWindowsAttribute as CFString) else { return [] }
        return windows.compactMap { window in
            let title = (AXHelper.string(window, kAXTitleAttribute as CFString) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let number = AXHelper.number(window, "AXWindowNumber" as CFString).map { CGWindowID(UInt32($0)) }
            return WindowInfo(number: number, title: title)
        }
    }

    static func isListable(_ window: AXUIElement) -> Bool {
        let role = AXHelper.string(window, kAXRoleAttribute as CFString) ?? ""
        guard role == (kAXWindowRole as String) else { return false }
        let subrole = AXHelper.string(window, kAXSubroleAttribute as CFString) ?? ""
        if WindowCatalog.skippedSubroles.contains(subrole) { return false }

        let minimized = AXHelper.bool(window, kAXMinimizedAttribute as CFString) ?? false
        let size = AXHelper.size(window, kAXSizeAttribute as CFString) ?? .zero
        if !minimized, size.width < 80 || size.height < 80 { return false }

        let title = (AXHelper.string(window, kAXTitleAttribute as CFString) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if WindowCatalog.isJunkTitle(title) { return false }
        if title.isEmpty, !minimized, size.width < 200 || size.height < 120 { return false }
        return true
    }

    private static func findWindow(pid: pid_t, windowID: CGWindowID, title: String?, axIndex: Int?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let windows = AXHelper.children(app, attribute: kAXWindowsAttribute as CFString) else { return nil }
        let listable = windows.filter(isListable)

        if windowID != 0 {
            for window in listable {
                if let number = AXHelper.number(window, "AXWindowNumber" as CFString),
                   CGWindowID(UInt32(number)) == windowID {
                    return window
                }
            }
        }
        if let title, !title.isEmpty {
            if let match = listable.first(where: { AXHelper.string($0, kAXTitleAttribute as CFString) == title }) {
                return match
            }
        }
        if let axIndex, listable.indices.contains(axIndex) {
            return listable[axIndex]
        }
        return nil
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

    static func bool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? Bool
    }

    static func size(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func children(_ element: AXUIElement, attribute: CFString = kAXChildrenAttribute as CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }
}
