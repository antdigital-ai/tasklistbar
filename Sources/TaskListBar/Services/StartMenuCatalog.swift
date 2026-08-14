import AppKit
import Combine
import Foundation

struct StartMenuApp: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    let url: URL
    let category: AppCategory

    var icon: NSImage {
        AppIconCache.icon(forFile: url.path, size: 48)
    }
}

private struct CachedStartMenuApp: Codable, Equatable {
    let bundleIdentifier: String
    let name: String
    let path: String
    let category: String?
}

@MainActor
final class StartMenuCatalog: ObservableObject {
    @Published private(set) var apps: [StartMenuApp] = []
    @Published private(set) var filteredApps: [StartMenuApp] = []
    @Published private(set) var categoryGroups: [StartMenuCategoryGroup] = []
    @Published private(set) var isLoading = false
    @Published var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleFilter()
        }
    }
    @Published var selectedCategory: AppCategory?

    private var lastScanAt: Date?
    private var lastFingerprint: String = ""
    private var scanTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private let cacheTTL: TimeInterval = 600

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var cacheURL: URL {
        AppSupport.root.appendingPathComponent("start-menu-apps-v2.json")
    }

    init() {
        Task { [weak self] in
            await self?.restoreDiskCache()
            self?.refresh(force: false)
        }
    }

    func refresh(force: Bool = false) {
        if !force,
           let lastScanAt,
           Date().timeIntervalSince(lastScanAt) < cacheTTL,
           !apps.isEmpty {
            return
        }

        if scanTask != nil, !force { return }

        scanTask?.cancel()
        isLoading = apps.isEmpty

        scanTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .utility) {
                Self.scanApplications()
            }.value
            guard !Task.isCancelled else { return }

            let fingerprint = discovered.map { "\($0.bundleIdentifier):\($0.category.rawValue)" }.joined(separator: "|")
            guard let self else { return }

            if fingerprint == self.lastFingerprint, !self.apps.isEmpty {
                self.lastScanAt = Date()
                self.isLoading = false
                self.scanTask = nil
                return
            }

            self.apps = discovered
            self.lastFingerprint = fingerprint
            self.lastScanAt = Date()
            self.isLoading = false
            self.applyFilterImmediately()
            self.scanTask = nil

            let cached = discovered.map {
                CachedStartMenuApp(
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.name,
                    path: $0.url.path,
                    category: $0.category.rawValue
                )
            }
            let url = self.cacheURL
            Task.detached(priority: .background) {
                Self.writeDiskCache(cached, to: url)
            }
        }
    }

    func launch(_ app: StartMenuApp) {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == app.bundleIdentifier && !$0.isTerminated
        }) {
            AppActivation.bringToFront(running)
            return
        }
        AppActivation.open(url: app.url)
    }

    func openCategory(_ category: AppCategory) {
        selectedCategory = category
        searchText = ""
    }

    func clearCategory() {
        selectedCategory = nil
    }

    private func restoreDiskCache() async {
        let url = cacheURL
        let restored = await Task.detached(priority: .utility) { () -> [StartMenuApp]? in
            guard let cached = Self.readDiskCache(from: url), !cached.isEmpty else { return nil }
            var apps: [StartMenuApp] = []
            apps.reserveCapacity(cached.count)
            for item in cached {
                let pathURL = URL(fileURLWithPath: item.path)
                guard FileManager.default.fileExists(atPath: item.path) else { continue }
                let category = AppCategory(rawValue: item.category ?? "")
                    ?? AppCategory.infer(bundleID: item.bundleIdentifier, name: item.name)
                apps.append(
                    StartMenuApp(
                        bundleIdentifier: item.bundleIdentifier,
                        name: item.name,
                        url: pathURL,
                        category: category
                    )
                )
            }
            return apps.isEmpty ? nil : apps
        }.value

        guard let restored, apps.isEmpty else { return }
        apps = restored
        lastFingerprint = restored.map { "\($0.bundleIdentifier):\($0.category.rawValue)" }.joined(separator: "|")
        lastScanAt = Date().addingTimeInterval(-cacheTTL / 2)
        applyFilterImmediately()
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
        let source: [StartMenuApp]
        if query.isEmpty {
            source = apps
        } else {
            source = apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        filteredApps = source
        categoryGroups = Self.buildGroups(from: source)
    }

    nonisolated private static func buildGroups(from apps: [StartMenuApp]) -> [StartMenuCategoryGroup] {
        let grouped = Dictionary(grouping: apps, by: \.category)
        return grouped.keys
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { category in
                guard let list = grouped[category], !list.isEmpty else { return nil }
                let sorted = list.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return StartMenuCategoryGroup(category: category, apps: sorted)
            }
    }

    nonisolated private static func readDiskCache(from url: URL) -> [CachedStartMenuApp]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CachedStartMenuApp].self, from: data)
    }

    nonisolated private static func writeDiskCache(_ apps: [CachedStartMenuApp], to url: URL) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: url, options: [.atomic])
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

            if let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) {
                for item in children where item.pathExtension == "app" {
                    appendApp(at: item, seen: &seen, results: &results)
                }
            }

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
        let rawCategory = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        var category = AppCategory.from(lsApplicationCategoryType: rawCategory)
        if category == .other {
            category = AppCategory.infer(bundleID: bid, name: name)
        }
        results.append(
            StartMenuApp(
                bundleIdentifier: bid,
                name: name,
                url: item,
                category: category
            )
        )
    }
}
