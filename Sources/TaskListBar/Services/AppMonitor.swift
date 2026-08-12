import AppKit
import Combine
import Foundation

@MainActor
final class AppMonitor: ObservableObject {
    @Published private(set) var runningApps: [NSRunningApplication] = []
    @Published private(set) var frontmostBundleID: String?

    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var lastSignature: String = ""

    func start() {
        refresh(immediate: true)

        let workspace = NSWorkspace.shared.notificationCenter
        // Focus + lifecycle only. Hide/unhide/deactivate spam rebuilds without changing the list.
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]

        for name in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh()
                }
            }
            observers.append(token)
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
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
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard let bid = app.bundleIdentifier else { return false }
            return bid != AppItemFactory.ownBundleID
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

    func activateOrLaunch(item: TaskbarAppItem) {
        if item.isRunning, let pid = item.processIdentifier,
           let running = NSRunningApplication(processIdentifier: pid) {
            if item.isActive {
                running.hide()
            } else {
                running.unhide()
                running.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }

        if let running = runningApps.first(where: { $0.bundleIdentifier == item.bundleIdentifier }) {
            if running.isActive {
                running.hide()
            } else {
                running.unhide()
                running.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }

        guard let url = item.url ?? AppIconCache.url(forBundleID: item.bundleIdentifier) else {
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
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
