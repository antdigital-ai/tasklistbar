import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppMonitor: ObservableObject {
    @Published private(set) var runningApps: [NSRunningApplication] = []
    @Published private(set) var frontmostBundleID: String?

    let windowCatalog = WindowCatalog()

    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var debounceTask: Task<Void, Never>?
    private var lastSignature: String = ""

    func start() {
        refreshFrontmost()
        windowCatalog.$uiPIDs
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] pids in
                self?.applyRunning(uiPIDs: pids)
            }
            .store(in: &cancellables)
        windowCatalog.start()

        let workspace = NSWorkspace.shared.notificationCenter
        let runningNames: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        for name in runningNames {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleRunningRefresh()
                    }
                }
            )
        }
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshFrontmost()
                }
            }
        )
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        windowCatalog.stop()
        cancellables.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        for token in observers {
            workspace.removeObserver(token)
        }
        observers.removeAll()
    }

    private func scheduleRunningRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.refreshRunning()
            }
        }
    }

    func refreshFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front != frontmostBundleID else { return }
        frontmostBundleID = front
    }

    func refreshRunning() {
        applyRunning(uiPIDs: windowCatalog.uiPIDs)
        windowCatalog.refresh()
    }

    private func applyRunning(uiPIDs: Set<pid_t>) {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard let bid = app.bundleIdentifier else { return false }
            guard bid != AppItemFactory.ownBundleID else { return false }
            return uiPIDs.contains(app.processIdentifier)
        }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let signature = apps.map { "\($0.bundleIdentifier ?? "")#\($0.processIdentifier)" }.joined(separator: "|")
            + "<\(front ?? "")>"

        guard signature != lastSignature else { return }
        lastSignature = signature
        runningApps = apps
        if front != frontmostBundleID {
            frontmostBundleID = front
        }
    }

    func activateOrLaunch(item: TaskbarAppItem) {
        if item.isFolder {
            if let url = item.url {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if let running = resolvedRunning(for: item) {
            AppLog.info(
                "匹配运行进程 \(item.name) pid=\(running.processIdentifier) active=\(running.isActive) hidden=\(running.isHidden) policy=\(running.activationPolicy.rawValue)",
                category: "apps"
            )
            if let windowID = item.windowID {
                if item.isActive {
                    AppLog.info("最小化窗口 \(item.name) window=\(windowID)", category: "apps")
                    if !WindowRaiser.minimize(
                        pid: running.processIdentifier,
                        windowID: windowID,
                        title: item.windowTitle,
                        axIndex: item.windowIndex
                    ) {
                        running.hide()
                    }
                    return
                }
                AppActivation.bringToFront(
                    running,
                    windowID: windowID,
                    windowTitle: item.windowTitle,
                    axIndex: item.windowIndex
                )
                return
            }
            if item.isActive || running.isActive {
                if running.isActive, AppActivation.hasOnScreenWindow(running) {
                    AppLog.info("隐藏前台应用 \(item.name) pid=\(running.processIdentifier)", category: "apps")
                    running.hide()
                    return
                }
                AppLog.info(
                    "忽略过期 active 状态并重新激活 \(item.name) pid=\(running.processIdentifier) itemActive=\(item.isActive) processActive=\(running.isActive)",
                    category: "apps"
                )
            }
            AppActivation.bringToFront(running)
            return
        }

        guard let url = item.url ?? AppIconCache.url(forBundleID: item.bundleIdentifier) else {
            AppLog.warn("找不到 \(item.name) 的路径", category: "apps")
            return
        }
        AppLog.info("启动未运行应用 \(item.name) path=\(url.path)", category: "apps")
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

    func raise(window: CatalogWindow) {
        guard let running = NSRunningApplication(processIdentifier: window.pid), !running.isTerminated else { return }
        AppActivation.bringToFront(
            running,
            windowID: window.windowID,
            windowTitle: window.title,
            axIndex: window.axIndex
        )
    }

    func closeWindow(_ item: TaskbarAppItem) {
        guard let windowID = item.windowID, let pid = item.processIdentifier else { return }
        WindowRaiser.close(pid: pid, windowID: windowID, title: item.windowTitle, axIndex: item.windowIndex)
        windowCatalog.refresh()
    }
}

enum AppActivation {
    static func bringToFront(
        _ running: NSRunningApplication,
        allowOpenFallback: Bool = true,
        windowID: CGWindowID? = nil,
        windowTitle: String? = nil,
        axIndex: Int? = nil
    ) {
        guard !running.isTerminated else { return }
        AppLog.info(
            "开始激活 \(running.localizedName ?? "?") pid=\(running.processIdentifier) active=\(running.isActive) hidden=\(running.isHidden) policy=\(running.activationPolicy.rawValue) fallback=\(allowOpenFallback)",
            category: "apps"
        )
        running.unhide()

        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: running)
            _ = running.activate()
        }
        running.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        if let windowID {
            WindowRaiser.raise(pid: running.processIdentifier, windowID: windowID, title: windowTitle, axIndex: axIndex)
        } else {
            raiseWindows(of: running)
        }

        if isAgentApp(running), openCustomActivationURL(for: running) {
            AppLog.info("Agent 应用改用协议激活 \(running.localizedName ?? "?")", category: "apps")
            return
        }

        let immediatelyVisible = hasOnScreenWindow(running)
        if running.isActive, immediatelyVisible {
            AppLog.info("原生激活立即成功且窗口可见 \(running.localizedName ?? "?")", category: "apps")
            return
        }

        // Activation is asynchronous on recent macOS releases. Waiting briefly avoids
        // invoking an app's deep-link protocol during an otherwise normal launch.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !running.isTerminated else {
                AppLog.warn("激活期间进程已退出 pid=\(running.processIdentifier)", category: "apps")
                return
            }
            let visible = hasOnScreenWindow(running)
            if running.isActive, visible {
                AppLog.info("原生激活延迟成功且窗口可见 \(running.localizedName ?? "?") pid=\(running.processIdentifier)", category: "apps")
                return
            }
            AppLog.warn(
                "原生 activate 未显示窗口 \(running.localizedName ?? "?") pid=\(running.processIdentifier) active=\(running.isActive) visible=\(visible)",
                category: "apps"
            )

            // Re-opening the exact bundle is the closest NSWorkspace equivalent of
            // `open -a /path/App.app` and is more reliable than a bare deep link.
            if allowOpenFallback, let url = running.bundleURL {
                AppLog.info("尝试按路径重新打开 \(running.localizedName ?? "?") path=\(url.path)", category: "apps")
                open(url: url)
                return
            }
            if !openCustomActivationURL(for: running) {
                AppLog.warn("没有可用协议兜底 \(running.localizedName ?? "?")", category: "apps")
            }
        }
    }

    static func open(url: URL) {
        AppLog.info("请求 NSWorkspace 打开 path=\(url.path)", category: "apps")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { running, error in
            if let error {
                AppLog.warn("NSWorkspace 打开失败 \(url.lastPathComponent): \(error.localizedDescription)", category: "apps")
                if !openCustomActivationURL(forBundleAt: url) {
                    AppLog.warn("没有协议可继续尝试 \(url.lastPathComponent)", category: "apps")
                }
                return
            }
            guard let running else {
                AppLog.warn("NSWorkspace 未返回运行进程 \(url.lastPathComponent)", category: "apps")
                if !openCustomActivationURL(forBundleAt: url) {
                    AppLog.warn("没有协议可继续尝试 \(url.lastPathComponent)", category: "apps")
                }
                return
            }
            AppLog.info(
                "NSWorkspace 打开完成 \(url.lastPathComponent) pid=\(running.processIdentifier) active=\(running.isActive) finished=\(running.isFinishedLaunching)",
                category: "apps"
            )
            Task { @MainActor in
                bringToFront(running, allowOpenFallback: false)
            }
        }
    }

    /// `NSRunningApplication.isActive` can become true while an app's window remains
    /// on another Space. Treat activation as successful only when a real window is
    /// visible on the current Space.
    static func hasOnScreenWindow(_ running: NSRunningApplication) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return infoList.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == running.processIdentifier else { return false }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return false }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { return false }
            guard let raw = info[kCGWindowBounds as String] as? [String: Any] else { return false }
            let width = (raw["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (raw["Height"] as? NSNumber)?.doubleValue ?? 0
            return width >= 80 && height >= 80
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

    @discardableResult
    private static func openCustomActivationURL(for running: NSRunningApplication) -> Bool {
        guard let bundleURL = running.bundleURL else { return false }
        return openCustomActivationURL(
            forBundleAt: bundleURL,
            bundleIdentifier: running.bundleIdentifier,
            localizedName: running.localizedName
        )
    }

    @discardableResult
    private static func openCustomActivationURL(forBundleAt bundleURL: URL) -> Bool {
        openCustomActivationURL(forBundleAt: bundleURL, bundleIdentifier: nil, localizedName: nil)
    }

    @discardableResult
    private static func openCustomActivationURL(
        forBundleAt bundleURL: URL,
        bundleIdentifier: String?,
        localizedName: String?
    ) -> Bool {
        guard let bundle = Bundle(url: bundleURL), let info = bundle.infoDictionary else { return false }
        let schemes = ActivationSchemeResolver.candidates(
            infoDictionary: info,
            bundleIdentifier: bundleIdentifier ?? bundle.bundleIdentifier,
            localizedName: localizedName
        )
        guard !schemes.isEmpty else {
            AppLog.info("未找到安全的唤醒协议 \(bundleURL.lastPathComponent)", category: "apps")
            return false
        }
        AppLog.info("协议候选 \(bundleURL.lastPathComponent): \(schemes.joined(separator: ","))", category: "apps")

        openActivationCandidate(schemes, at: 0, forBundleAt: bundleURL)
        return true
    }

    private static func openActivationCandidate(_ schemes: [String], at index: Int, forBundleAt bundleURL: URL) {
        guard schemes.indices.contains(index), let activationURL = URL(string: "\(schemes[index]):") else {
            AppLog.warn("所有协议均无法唤醒 \(bundleURL.lastPathComponent)", category: "apps")
            return
        }
        let scheme = schemes[index]

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.open(
            [activationURL],
            withApplicationAt: bundleURL,
            configuration: config
        ) { launched, error in
            if let error {
                AppLog.warn("协议唤醒失败 \(bundleURL.lastPathComponent) [\(scheme)]: \(error.localizedDescription)", category: "apps")
                openActivationCandidate(schemes, at: index + 1, forBundleAt: bundleURL)
                return
            }
            guard let launched else {
                AppLog.warn("协议已投递但未返回进程 \(bundleURL.lastPathComponent) [\(scheme)]", category: "apps")
                return
            }
            AppLog.info(
                "协议投递完成 \(bundleURL.lastPathComponent) [\(scheme)] pid=\(launched.processIdentifier) active=\(launched.isActive)",
                category: "apps"
            )
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                launched.unhide()
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: launched)
                    _ = launched.activate()
                }
                launched.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                raiseWindows(of: launched)
                try? await Task.sleep(nanoseconds: 180_000_000)
                AppLog.info(
                    "协议激活结果 \(bundleURL.lastPathComponent) [\(scheme)] active=\(launched.isActive) hidden=\(launched.isHidden)",
                    category: "apps"
                )
            }
        }
        AppLog.info("使用协议唤醒 \(bundleURL.lastPathComponent) [\(scheme)]", category: "apps")
    }
}
