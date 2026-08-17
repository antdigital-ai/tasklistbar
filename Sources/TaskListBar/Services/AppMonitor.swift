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
            if let windowID = item.windowID {
                if item.isActive {
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
    private static let genericSchemes: Set<String> = [
        "http", "https", "file", "mailto", "ftp", "tel", "sms", "webcal", "afp", "smb", "cifs"
    ]
    private static let rejectedSchemeParts = [
        "license", "oauth", "callback", "uninstall", "update", "auth", "prefs", "feed", "helper"
    ]
    private static let weakTokens: Set<String> = [
        "com", "org", "net", "mac", "app", "ios", "osx", "www", "desktop", "exclusive", "work"
    ]

    static func bringToFront(
        _ running: NSRunningApplication,
        allowOpenFallback: Bool = true,
        windowID: CGWindowID? = nil,
        windowTitle: String? = nil,
        axIndex: Int? = nil
    ) {
        guard !running.isTerminated else { return }
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

        let needsURL = isAgentApp(running) || !running.isActive
        if needsURL, let url = customActivationURL(for: running) {
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

        let schemes = types
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .map { $0.lowercased() }
            .filter { isActivationScheme($0) }
        guard !schemes.isEmpty else { return nil }

        let tokens = identityTokens(for: running, bundle: bundle)
        let ranked = schemes.map { ($0, score(scheme: $0, tokens: tokens)) }
        guard let best = ranked.max(by: { $0.1 < $1.1 }), best.1 >= 3 else { return nil }
        return URL(string: "\(best.0):")
    }

    private static func isActivationScheme(_ scheme: String) -> Bool {
        guard !scheme.isEmpty, !genericSchemes.contains(scheme) else { return false }
        return !rejectedSchemeParts.contains { scheme.contains($0) }
    }

    private static func identityTokens(for running: NSRunningApplication, bundle: Bundle) -> Set<String> {
        var raw: [String] = []
        if let bid = running.bundleIdentifier { raw.append(bid) }
        if let name = running.localizedName { raw.append(name) }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String { raw.append(name) }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String { raw.append(name) }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String { raw.append(name) }

        var tokens = Set<String>()
        for value in raw {
            let lower = value.lowercased()
            for piece in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let token = String(piece)
                guard token.count >= 4, !weakTokens.contains(token) else { continue }
                tokens.insert(token)
            }
        }
        return tokens
    }

    private static func score(scheme: String, tokens: Set<String>) -> Int {
        let compact = scheme.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined()
        if tokens.contains(scheme) || tokens.contains(compact) { return 3 }
        if tokens.contains(where: { $0.count >= 4 && (scheme == $0 || compact == $0) }) { return 3 }
        if tokens.contains(where: { $0.count >= 4 && (scheme.contains($0) || $0.contains(scheme)) }) { return 2 }
        return 1
    }
}
