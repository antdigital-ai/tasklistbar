import AppKit
import Combine
import Foundation

struct StartMenuApp: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let url: URL
}

@MainActor
final class StartMenuCatalog: ObservableObject {
    @Published private(set) var apps: [StartMenuApp] = []
    @Published private(set) var filteredApps: [StartMenuApp] = []
    @Published var searchText: String = "" {
        didSet { scheduleFilter() }
    }

    private var lastScanAt: Date?
    private var scanTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private let cacheTTL: TimeInterval = 300

    func refresh(force: Bool = false) {
        if !force,
           let lastScanAt,
           Date().timeIntervalSince(lastScanAt) < cacheTTL,
           !apps.isEmpty {
            return
        }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .utility) {
                Self.scanApplications()
            }.value
            guard !Task.isCancelled else { return }
            self?.apps = discovered
            self?.lastScanAt = Date()
            self?.applyFilterImmediately()
        }
    }

    func launch(_ app: StartMenuApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config)
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            applyFilterImmediately()
        }
    }

    private func applyFilterImmediately() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredApps = apps
        } else {
            filteredApps = apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    nonisolated private static func scanApplications() -> [StartMenuApp] {
        let directories = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        var seen = Set<String>()
        var results: [StartMenuApp] = []
        results.reserveCapacity(128)

        for directory in directories {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Prefer shallow listing — most apps live directly under Applications.
            if let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in children where item.pathExtension == "app" {
                    appendApp(at: item, seen: &seen, results: &results)
                }
            }

            // One extra level for folders like /Applications/Utilities (already covered)
            // and vendor groupings under ~/Applications.
            if directory.hasSuffix("/Applications"),
               let children = try? FileManager.default.contentsOfDirectory(
                   at: url,
                   includingPropertiesForKeys: [.isDirectoryKey],
                   options: [.skipsHiddenFiles]
               ) {
                for child in children {
                    var childIsDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDir),
                          childIsDir.boolValue,
                          child.pathExtension != "app"
                    else { continue }
                    if let nested = try? FileManager.default.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: [.isApplicationKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for item in nested where item.pathExtension == "app" {
                            appendApp(at: item, seen: &seen, results: &results)
                        }
                    }
                }
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func appendApp(
        at item: URL,
        seen: inout Set<String>,
        results: inout [StartMenuApp]
    ) {
        guard let bundle = Bundle(url: item),
              let bid = bundle.bundleIdentifier,
              !seen.contains(bid)
        else { return }

        if let policy = bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, policy {
            return
        }
        if let policy = bundle.object(forInfoDictionaryKey: "LSUIElement") as? String, policy == "1" {
            return
        }

        seen.insert(bid)
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? item.deletingPathExtension().lastPathComponent
        let icon = AppIconCache.icon(forFile: item.path, size: 64)

        results.append(
            StartMenuApp(
                bundleIdentifier: bid,
                name: name,
                icon: icon,
                url: item
            )
        )
    }
}
