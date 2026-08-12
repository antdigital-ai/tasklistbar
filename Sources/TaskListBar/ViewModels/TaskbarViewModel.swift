import AppKit
import Combine
import Foundation

@MainActor
final class TaskbarViewModel: ObservableObject {
    @Published private(set) var items: [TaskbarAppItem] = []
    @Published var isStartMenuOpen = false
    @Published var isModifierKeysOpen = false
    @Published var showsAllApps = false

    let appMonitor: AppMonitor
    let pinnedStore: PinnedAppsStore
    let startMenuCatalog: StartMenuCatalog
    let modifierKeyRemapper: ModifierKeyRemapper
    let batteryMonitor: BatteryMonitor
    let spacesMonitor: SpacesMonitor
    let trashMonitor: TrashMonitor
    let clockModel = ClockModel()

    private var cancellables = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var lastItemsSignature = ""

    init(
        appMonitor: AppMonitor,
        pinnedStore: PinnedAppsStore,
        startMenuCatalog: StartMenuCatalog,
        modifierKeyRemapper: ModifierKeyRemapper,
        batteryMonitor: BatteryMonitor,
        spacesMonitor: SpacesMonitor,
        trashMonitor: TrashMonitor
    ) {
        self.appMonitor = appMonitor
        self.pinnedStore = pinnedStore
        self.startMenuCatalog = startMenuCatalog
        self.modifierKeyRemapper = modifierKeyRemapper
        self.batteryMonitor = batteryMonitor
        self.spacesMonitor = spacesMonitor
        self.trashMonitor = trashMonitor

        appMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        pinnedStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        rebuildItems()
        // Warm start-menu cache in background after launch.
        startMenuCatalog.refresh(force: false)
    }

    func startTrayMonitors() {
        batteryMonitor.start()
        spacesMonitor.start()
        trashMonitor.start()
        clockModel.start()
    }

    func stopTrayMonitors() {
        batteryMonitor.stop()
        spacesMonitor.stop()
        trashMonitor.stop()
        clockModel.stop()
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            rebuildItems()
        }
    }

    func rebuildItems() {
        let running = appMonitor.runningApps
        let frontID = appMonitor.frontmostBundleID
        var result: [TaskbarAppItem] = []
        result.reserveCapacity(pinnedStore.pinnedBundleIDs.count + running.count)
        var seen = Set<String>()

        let runningByID = Dictionary(
            running.compactMap { app -> (String, NSRunningApplication)? in
                guard let bid = app.bundleIdentifier else { return nil }
                return (bid, app)
            },
            uniquingKeysWith: { first, _ in first }
        )

        for bid in pinnedStore.pinnedBundleIDs {
            seen.insert(bid)
            let runningMatch = runningByID[bid]
            let url = runningMatch?.bundleURL ?? AppIconCache.url(forBundleID: bid)
            let name = AppIconCache.displayName(
                forBundleID: bid,
                url: url,
                runningName: runningMatch?.localizedName
            )
            let icon = AppIconCache.icon(
                forBundleID: bid,
                url: url,
                fallback: runningMatch?.icon,
                size: 64
            )

            result.append(
                AppItemFactory.make(
                    bundleIdentifier: bid,
                    name: name,
                    icon: icon,
                    url: url,
                    isRunning: runningMatch != nil,
                    isActive: frontID == bid,
                    isPinned: true,
                    processIdentifier: runningMatch?.processIdentifier
                )
            )
        }

        for app in running {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            result.append(
                AppItemFactory.make(
                    bundleIdentifier: bid,
                    name: app.localizedName ?? bid,
                    icon: app.icon,
                    url: app.bundleURL,
                    isRunning: true,
                    isActive: frontID == bid,
                    isPinned: false,
                    processIdentifier: app.processIdentifier
                )
            )
        }

        let signature = result.map {
            "\($0.bundleIdentifier):\($0.isRunning ? 1 : 0)\($0.isActive ? 1 : 0)\($0.isPinned ? 1 : 0)"
        }.joined(separator: ",")
        guard signature != lastItemsSignature else { return }
        lastItemsSignature = signature
        items = result
    }

    func select(_ item: TaskbarAppItem) {
        isStartMenuOpen = false
        isModifierKeysOpen = false
        appMonitor.activateOrLaunch(item: item)
    }

    func toggleStartMenu() {
        isStartMenuOpen.toggle()
        if isStartMenuOpen {
            isModifierKeysOpen = false
            showsAllApps = false
            startMenuCatalog.searchText = ""
            startMenuCatalog.refresh(force: false)
        } else {
            showsAllApps = false
        }
    }

    func closeStartMenu() {
        isStartMenuOpen = false
        showsAllApps = false
        startMenuCatalog.searchText = ""
    }

    func openAllApps() {
        showsAllApps = true
        startMenuCatalog.searchText = ""
        startMenuCatalog.refresh(force: false)
    }

    func backToStartHome() {
        showsAllApps = false
        startMenuCatalog.searchText = ""
    }

    func openModifierKeysSettings() {
        isStartMenuOpen = false
        showsAllApps = false
        startMenuCatalog.searchText = ""
        isModifierKeysOpen = true
        modifierKeyRemapper.reapply()
    }

    func closeModifierKeysSettings() {
        isModifierKeysOpen = false
    }

    func pin(_ item: TaskbarAppItem) {
        pinnedStore.pin(item.bundleIdentifier)
    }

    func unpin(_ item: TaskbarAppItem) {
        pinnedStore.unpin(item.bundleIdentifier)
    }

    func quit(_ item: TaskbarAppItem) {
        appMonitor.quit(bundleIdentifier: item.bundleIdentifier)
    }

    func launchFromStartMenu(_ app: StartMenuApp) {
        closeStartMenu()
        startMenuCatalog.launch(app)
    }

    func pinFromStartMenu(_ app: StartMenuApp) {
        pinnedStore.pin(app.bundleIdentifier)
    }
}
