import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppMonitor: ObservableObject {
    @Published private(set) var runningApps: [NSRunningApplication] = []
    @Published private(set) var frontmostBundleID: String?

    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var windowPollTask: Task<Void, Never>?
    private var lastSignature: String = ""

    func start() {
        refresh(immediate: true)

        let workspace = NSWorkspace.shared.notificationCenter
        // Focus + lifecycle + hide. Window open/close is covered by a light poll.
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]

        for name in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh()
                }
            }
            observers.append(token)
        }

        windowPollTask?.cancel()
        windowPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refresh(immediate: true)
                }
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        windowPollTask?.cancel()
        windowPollTask = nil
        let workspace = NSWorkspace.shared.notificationCenter
        for token in observers {
            workspace.removeObserver(token)
        }
        observers.removeAll()
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms coalesce
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.refresh(immediate: true)
            }
        }
    }

    func refresh(immediate: Bool = true) {
        _ = immediate
        let uiPIDs = Self.pidsWithUIWindows()
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard let bid = app.bundleIdentifier else { return false }
            guard bid != AppItemFactory.ownBundleID else { return false }
            // Skip background/agent processes that declare .regular but have no real UI.
            return uiPIDs.contains(app.processIdentifier)
        }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let signature = apps.map { "\($0.bundleIdentifier ?? "")#\($0.processIdentifier)" }.joined(separator: "|")
            + "<\(front ?? "")>"

        guard signature != lastSignature else { return }
        lastSignature = signature
        runningApps = apps
        frontmostBundleID = front
    }

    /// Layer-0 windows large enough to count as real app UI (not 1×1 agents / menu crumbs).
    private static func pidsWithUIWindows() -> Set<pid_t> {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result = Set<pid_t>()
        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }

            if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
                let width = cgFloatValue(bounds["Width"])
                let height = cgFloatValue(bounds["Height"])
                // Tiny / off-screen agent windows should not keep an app in the taskbar.
                if width < 50 || height < 50 { continue }
            }

            result.insert(pid)
        }
        return result
    }

    private static func cgFloatValue(_ raw: Any?) -> CGFloat {
        if let number = raw as? NSNumber { return CGFloat(truncating: number) }
        if let value = raw as? CGFloat { return value }
        if let value = raw as? Double { return CGFloat(value) }
        return 0
    }

    func activateOrLaunch(item: TaskbarAppItem) {
        if let running = resolvedRunning(for: item) {
            if item.isActive || running.isActive {
                running.hide()
                return
            }
            AppActivation.bringToFront(running)
            return
        }

        guard let url = item.url ?? AppIconCache.url(forBundleID: item.bundleIdentifier) else {
            AppLog.warn("找不到 \(item.name) 的路径", category: "apps")
            return
        }
        AppActivation.open(url: url)
    }

    private func resolvedRunning(for item: TaskbarAppItem) -> NSRunningApplication? {
        if item.isRunning, let pid = item.processIdentifier,
           let running = NSRunningApplication(processIdentifier: pid),
           !running.isTerminated {
            return running
        }
        if let running = runningApps.first(where: {
            $0.bundleIdentifier == item.bundleIdentifier && !$0.isTerminated
        }) {
            return running
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == item.bundleIdentifier && !$0.isTerminated
        }
    }

    func quit(bundleIdentifier: String) {
        runningApps
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .forEach { $0.terminate() }
    }

    func forceQuit(bundleIdentifier: String) {
        runningApps
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .forEach { $0.forceTerminate() }
    }
}

enum AppActivation {
    static func bringToFront(_ running: NSRunningApplication, allowOpenFallback: Bool = true) {
        guard !running.isTerminated else { return }
        running.unhide()

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: running)
            _ = running.activate()
        }
        running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        raiseWindows(of: running)

        if isAgentApp(running), let url = customActivationURL(for: running) {
            NSWorkspace.shared.open(url)
            return
        }

        if running.isActive {
            return
        }

        guard allowOpenFallback, let url = running.bundleURL else { return }
        open(url: url)
    }

    static func open(url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { running, error in
            if let error {
                AppLog.warn("打开失败 \(url.lastPathComponent): \(error.localizedDescription)", category: "apps")
                return
            }
            guard let running else { return }
            Task { @MainActor in
                bringToFront(running, allowOpenFallback: false)
            }
        }
    }

    private static func raiseWindows(of running: NSRunningApplication) {
        let app = AXUIElementCreateApplication(running.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return }

        for window in windows {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private static func isAgentApp(_ running: NSRunningApplication) -> Bool {
        if running.activationPolicy != .regular { return true }
        guard let url = running.bundleURL, let bundle = Bundle(url: url) else { return false }
        if let flag = bundle.object(forInfoDictionaryKey: "LSUIElement") as? NSNumber {
            return flag.boolValue
        }
        if let flag = bundle.object(forInfoDictionaryKey: "LSUIElement") as? String {
            return flag == "1" || flag.lowercased() == "true"
        }
        return false
    }

    private static func customActivationURL(for running: NSRunningApplication) -> URL? {
        guard let bundleURL = running.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let types = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
        else { return nil }

        let blocked: Set<String> = ["http", "https", "file", "mailto", "ftp", "tel", "sms"]
        let schemes = types
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .map { $0.lowercased() }
            .filter { !blocked.contains($0) && !$0.isEmpty }
        guard !schemes.isEmpty else { return nil }

        let tokens = Set((running.bundleIdentifier ?? "").lowercased().split(separator: ".").map(String.init))
        let scheme = schemes.max { a, b in
            score(scheme: a, tokens: tokens) < score(scheme: b, tokens: tokens)
        } ?? schemes[0]
        return URL(string: "\(scheme):")
    }

    private static func score(scheme: String, tokens: Set<String>) -> Int {
        if tokens.contains(scheme) { return 3 }
        if tokens.contains(where: { $0.contains(scheme) || scheme.contains($0) }) { return 2 }
        return 1
    }
}
