import AppKit
import Combine
import Foundation

@MainActor
final class TaskbarViewModel: ObservableObject {
    @Published private(set) var items: [TaskbarAppItem] = []
    @Published var isStartMenuOpen = false
    @Published var isModifierKeysOpen = false
    @Published var isCalendarOpen = false
    @Published var isCalendarExpanded: Bool
    @Published var isCalendarAgendaExpanded = false
    @Published var isSettingsOpen = false
    @Published var isWindowListOpen = false
    @Published var windowListBundleID: String?
    @Published var windowListAppName = ""
    @Published var windowListIcon = NSImage()
    @Published var windowListAnchorX: CGFloat = 0
    @Published var showsAllApps = false
    @Published var calendarNavigate = CalendarNavigate()
    @Published private(set) var appStripAvailableWidth: CGFloat = 0

    struct CalendarNavigate: Equatable {
        var generation = 0
        var delta = 0
    }

    let appMonitor: AppMonitor
    let pinnedStore: PinnedAppsStore
    let startMenuCatalog: StartMenuCatalog
    let modifierKeyRemapper: ModifierKeyRemapper
    let appSettings: AppSettings
    let batteryMonitor: BatteryMonitor
    let spacesMonitor: SpacesMonitor
    let bluetoothMonitor: BluetoothMonitor
    let volumeMonitor: VolumeMonitor
    let favoritesStore: FavoritesStore
    let clockModel = ClockModel()
    let calendarStore = CalendarStore()
    let weatherStore = WeatherStore()

    private var cancellables = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var lastItemsSignature = ""

    init(
        appMonitor: AppMonitor,
        pinnedStore: PinnedAppsStore,
        startMenuCatalog: StartMenuCatalog,
        modifierKeyRemapper: ModifierKeyRemapper,
        appSettings: AppSettings,
        batteryMonitor: BatteryMonitor,
        spacesMonitor: SpacesMonitor,
        bluetoothMonitor: BluetoothMonitor,
        volumeMonitor: VolumeMonitor,
        favoritesStore: FavoritesStore
    ) {
        self.appMonitor = appMonitor
        self.pinnedStore = pinnedStore
        self.startMenuCatalog = startMenuCatalog
        self.modifierKeyRemapper = modifierKeyRemapper
        self.appSettings = appSettings
        self.batteryMonitor = batteryMonitor
        self.spacesMonitor = spacesMonitor
        self.bluetoothMonitor = bluetoothMonitor
        self.volumeMonitor = volumeMonitor
        self.favoritesStore = favoritesStore
        self.isCalendarExpanded = appSettings.calendarExpanded

        appMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        pinnedStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        appMonitor.windowCatalog.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        appSettings.$windowGrouping
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        appSettings.$showBadges
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.appMonitor.windowCatalog.includeDockExtras = enabled
                self.scheduleRebuild()
            }
            .store(in: &cancellables)

        appSettings.$barSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        $isWindowListOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                self?.appMonitor.windowCatalog.prefersFastPolling = open
            }
            .store(in: &cancellables)

        appMonitor.windowCatalog.includeDockExtras = appSettings.showBadges

        $isCalendarExpanded
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.appSettings.setCalendarExpanded(expanded)
                AppLog.info(expanded ? "日历展开为整月" : "日历收起为一周", category: "calendar")
            }
            .store(in: &cancellables)

        rebuildItems()
    }

    func startTrayMonitors() {
        batteryMonitor.start()
        spacesMonitor.start()
        bluetoothMonitor.start()
        volumeMonitor.start()
        clockModel.start()
        calendarStore.start()
        weatherStore.start()
        favoritesStore.start()
    }

    func stopTrayMonitors() {
        batteryMonitor.stop()
        spacesMonitor.stop()
        bluetoothMonitor.stop()
        volumeMonitor.stop()
        clockModel.stop()
        calendarStore.stop()
        favoritesStore.stop()
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            rebuildItems()
        }
    }

    func updateStripWidth(_ width: CGFloat) {
        guard abs(width - appStripAvailableWidth) > 8 else { return }
        appStripAvailableWidth = width
        rebuildItems()
    }

    func rebuildItems() {
        let running = appMonitor.runningApps
        let frontID = appMonitor.frontmostBundleID
        let frontWindowID = appMonitor.windowCatalog.frontmostWindowID
        let pinned = pinnedStore.pinnedBundleIDs
        let catalog = appMonitor.windowCatalog
        let showBadges = appSettings.showBadges

        let runningByID = Dictionary(
            running.compactMap { app -> (String, NSRunningApplication)? in
                guard let bid = app.bundleIdentifier else { return nil }
                return (bid, app)
            },
            uniquingKeysWith: { first, _ in first }
        )

        struct AppEntry {
            let bid: String
            let running: NSRunningApplication?
            let isPinned: Bool
            let windows: [CatalogWindow]
        }

        var entries: [AppEntry] = []
        var seen = Set<String>()
        seen.reserveCapacity(pinned.count + running.count)

        for bid in pinned {
            seen.insert(bid)
            entries.append(
                AppEntry(
                    bid: bid,
                    running: runningByID[bid],
                    isPinned: true,
                    windows: catalog.windows(for: bid)
                )
            )
        }
        for app in running {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            entries.append(
                AppEntry(
                    bid: bid,
                    running: app,
                    isPinned: false,
                    windows: catalog.windows(for: bid)
                )
            )
        }

        let grouped = shouldGroup(windowCounts: entries.map(\.windows.count))

        var signatureParts: [String] = []
        signatureParts.reserveCapacity(entries.count)
        for entry in entries {
            let badge = showBadges ? catalog.badges[entry.bid] ?? 0 : 0
            let progress = Int((catalog.progress[entry.bid] ?? -1) * 100)
            let hung = entry.running.map { catalog.unresponsivePIDs.contains($0.processIdentifier) } ?? false
            let active = frontID == entry.bid ? 1 : 0
            let windowPart = grouped
                ? "g\(entry.windows.count)"
                : entry.windows.map { "\($0.windowID):\($0.title)" }.joined(separator: "+")
            signatureParts.append(
                "\(entry.bid):\(entry.running == nil ? 0 : 1)\(active)\(entry.isPinned ? 1 : 0)|\(windowPart)|\(badge)|\(progress)|\(hung ? 1 : 0)|\(grouped ? 1 : 0)"
            )
        }
        let signature = signatureParts.joined(separator: ",") + "@\(Int(appStripAvailableWidth))"
        guard signature != lastItemsSignature else { return }
        lastItemsSignature = signature

        var result: [TaskbarAppItem] = []
        result.reserveCapacity(grouped ? entries.count : entries.reduce(0) { $0 + max($1.windows.count, 1) })

        for entry in entries {
            let url = entry.running?.bundleURL ?? AppIconCache.url(forBundleID: entry.bid)
            let name = AppIconCache.displayName(
                forBundleID: entry.bid,
                url: url,
                runningName: entry.running?.localizedName
            )
            let icon = AppIconCache.icon(
                forBundleID: entry.bid,
                url: url,
                fallback: entry.running?.icon,
                size: 64
            )
            let unread = showBadges ? catalog.badges[entry.bid] : nil
            let progress = catalog.progress[entry.bid]
            let hung = entry.running.map { catalog.unresponsivePIDs.contains($0.processIdentifier) } ?? false

            if !grouped, !entry.windows.isEmpty {
                for (index, window) in entry.windows.enumerated() {
                    result.append(
                        AppItemFactory.make(
                            bundleIdentifier: entry.bid,
                            name: name,
                            icon: icon,
                            url: url,
                            isRunning: true,
                            isActive: frontID == entry.bid && (frontWindowID == window.windowID || (frontWindowID == nil && index == 0)),
                            isPinned: entry.isPinned,
                            processIdentifier: window.pid,
                            windowID: window.windowID,
                            windowIndex: window.axIndex,
                            windowTitle: window.displayTitle(index: index),
                            windowCount: entry.windows.count,
                            badge: index == 0 ? unread : nil,
                            badgeIsUnread: index == 0 && unread != nil,
                            progress: index == 0 ? progress : nil,
                            isUnresponsive: hung,
                            isGrouped: false
                        )
                    )
                }
            } else {
                result.append(
                    AppItemFactory.make(
                        bundleIdentifier: entry.bid,
                        name: name,
                        icon: icon,
                        url: url,
                        isRunning: entry.running != nil,
                        isActive: frontID == entry.bid,
                        isPinned: entry.isPinned,
                        processIdentifier: entry.running?.processIdentifier,
                        windowCount: entry.windows.count,
                        badge: unread,
                        badgeIsUnread: unread != nil,
                        progress: progress,
                        isUnresponsive: hung,
                        isGrouped: true
                    )
                )
            }
        }

        items = result
    }

    private func shouldGroup(windowCounts: [Int]) -> Bool {
        switch appSettings.windowGrouping {
        case .always:
            return true
        case .never:
            return false
        case .automatic:
            guard appStripAvailableWidth > 40 else { return true }
            let tiles = windowCounts.reduce(0) { $0 + max($1, 1) }
            let needed = CGFloat(tiles) * (TaskbarMetrics.appButtonWidth + 2)
            return needed > appStripAvailableWidth
        }
    }

    func select(_ item: TaskbarAppItem) {
        if item.isGrouped, item.isRunning, item.windowCount >= 2 {
            if item.isActive {
                if isWindowListOpen, windowListBundleID == item.bundleIdentifier {
                    closeWindowList()
                } else {
                    closeOverlays(includingWindowList: false)
                    openWindowList(item)
                }
            } else {
                closeOverlays()
                appMonitor.activateOrLaunch(item: item)
            }
            return
        }
        closeOverlays()
        appMonitor.activateOrLaunch(item: item)
    }

    func openWindowList(_ item: TaskbarAppItem) {
        windowListBundleID = item.bundleIdentifier
        windowListAppName = item.name
        windowListIcon = item.icon
        windowListAnchorX = NSEvent.mouseLocation.x
        isWindowListOpen = true
    }

    func closeWindowList() {
        isWindowListOpen = false
        windowListBundleID = nil
    }

    func pickWindow(_ window: CatalogWindow) {
        closeOverlays()
        appMonitor.raise(window: window)
    }

    func closeWindow(_ item: TaskbarAppItem) {
        appMonitor.closeWindow(item)
    }

    func toggleStartMenu() {
        if isStartMenuOpen {
            isStartMenuOpen = false
            showsAllApps = false
            startMenuCatalog.selectedCategory = nil
            return
        }

        isModifierKeysOpen = false
        isCalendarOpen = false
        isSettingsOpen = false
        closeWindowList()
        showsAllApps = false
        startMenuCatalog.selectedCategory = nil
        if !startMenuCatalog.searchText.isEmpty {
            startMenuCatalog.searchText = ""
        }
        isStartMenuOpen = true
    }

    func closeStartMenu() {
        isStartMenuOpen = false
        showsAllApps = false
        startMenuCatalog.selectedCategory = nil
        startMenuCatalog.searchText = ""
    }

    func openAllApps() {
        showsAllApps = true
        startMenuCatalog.selectedCategory = nil
        startMenuCatalog.searchText = ""
        startMenuCatalog.refresh(force: false)
    }

    func backToStartHome() {
        showsAllApps = false
        startMenuCatalog.clearCategory()
        startMenuCatalog.searchText = ""
    }

    func toggleCalendarPreview() {
        isCalendarOpen.toggle()
        if isCalendarOpen {
        isStartMenuOpen = false
        showsAllApps = false
        isModifierKeysOpen = false
        isSettingsOpen = false
        closeWindowList()
        startMenuCatalog.selectedCategory = nil
        startMenuCatalog.searchText = ""
        calendarStore.prepare()
            calendarStore.load(month: Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date())
            weatherStore.refreshIfNeeded()
            isCalendarAgendaExpanded = false
            AppLog.info(isCalendarExpanded ? "打开日历（整月）" : "打开日历（一周）", category: "calendar")
        }
    }

    func closeCalendarPreview() {
        isCalendarOpen = false
        isCalendarAgendaExpanded = false
    }

    func openSystemCalendar() {
        closeCalendarPreview()
        let calendar = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        if FileManager.default.fileExists(atPath: calendar.path) {
            NSWorkspace.shared.open(calendar)
        }
    }

    func openModifierKeysSettings() {
        isStartMenuOpen = false
        showsAllApps = false
        isCalendarOpen = false
        isSettingsOpen = false
        closeWindowList()
        startMenuCatalog.searchText = ""
        isModifierKeysOpen = true
        modifierKeyRemapper.reapply()
    }

    func closeModifierKeysSettings() {
        isModifierKeysOpen = false
    }

    func openSettings() {
        isStartMenuOpen = false
        showsAllApps = false
        isCalendarOpen = false
        isModifierKeysOpen = false
        closeWindowList()
        startMenuCatalog.searchText = ""
        isSettingsOpen = true
    }

    func closeSettings() {
        appSettings.isRecordingHotkey = false
        isSettingsOpen = false
    }

    func closeOverlays(includingWindowList: Bool = true) {
        isStartMenuOpen = false
        isModifierKeysOpen = false
        isCalendarOpen = false
        isSettingsOpen = false
        isCalendarAgendaExpanded = false
        if includingWindowList {
            closeWindowList()
        }
        appSettings.isRecordingHotkey = false
        showsAllApps = false
        startMenuCatalog.selectedCategory = nil
        startMenuCatalog.searchText = ""
    }

    var hasOpenOverlay: Bool {
        isStartMenuOpen || isModifierKeysOpen || isCalendarOpen || isSettingsOpen || isCalendarAgendaExpanded || isWindowListOpen
    }

    func requestCalendarShift(_ delta: Int) {
        guard isCalendarOpen else { return }
        calendarNavigate = CalendarNavigate(generation: calendarNavigate.generation + 1, delta: delta)
    }

    func toggleCalendarMonth() {
        guard isCalendarOpen else { return }
        isCalendarExpanded.toggle()
        if isCalendarExpanded {
            isCalendarAgendaExpanded = false
        }
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
