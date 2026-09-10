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
    @Published var windowListHighlightedID: CGWindowID?
    @Published var windowListActiveWindowID: CGWindowID?
    @Published var showsAllApps = false
    @Published var calendarNavigate = CalendarNavigate()
    @Published private(set) var appStripAvailableWidth: CGFloat = 0
    private var unpinnedOrder: [String] = []

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
    let boostService = BoostService()
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
        boostService.start()
    }

    func stopTrayMonitors() {
        batteryMonitor.stop()
        spacesMonitor.stop()
        bluetoothMonitor.stop()
        volumeMonitor.stop()
        clockModel.stop()
        calendarStore.stop()
        favoritesStore.stop()
        boostService.stop()
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

        enum StripEntry {
            case app(AppEntry)
            case folder(PinnedItem, url: URL?)
        }

        var entries: [StripEntry] = []
        var seen = Set<String>()
        seen.reserveCapacity(pinnedStore.items.count + running.count)

        for pin in pinnedStore.items {
            if pin.isFolder {
                entries.append(.folder(pin, url: pinnedStore.resolvedURL(for: pin)))
                continue
            }
            let bid = pin.bundleID ?? pin.id
            seen.insert(bid)
            entries.append(
                .app(
                    AppEntry(
                        bid: bid,
                        running: runningByID[bid],
                        isPinned: true,
                        windows: catalog.windows(for: bid)
                    )
                )
            )
        }
        var unpinned: [(offset: Int, app: NSRunningApplication, bid: String)] = []
        for (offset, app) in running.enumerated() {
            guard let bid = app.bundleIdentifier, !seen.contains(bid) else { continue }
            seen.insert(bid)
            unpinned.append((offset, app, bid))
        }
        unpinned.sort { lhs, rhs in
            let left = unpinnedOrder.firstIndex(of: lhs.bid) ?? (10_000 + lhs.offset)
            let right = unpinnedOrder.firstIndex(of: rhs.bid) ?? (10_000 + rhs.offset)
            return left < right
        }
        for item in unpinned {
            entries.append(
                .app(
                    AppEntry(
                        bid: item.bid,
                        running: item.app,
                        isPinned: false,
                        windows: catalog.windows(for: item.bid)
                    )
                )
            )
        }

        let grouped = shouldGroup(
            windowCounts: entries.map { entry in
                if case .app(let app) = entry { return app.windows.count }
                return 0
            }
        )

        var signatureParts: [String] = []
        signatureParts.reserveCapacity(entries.count)
        for entry in entries {
            switch entry {
            case .folder(let pin, let url):
                signatureParts.append("folder:\(pin.id):\(pin.name):\(url?.path ?? "")")
            case .app(let app):
                let badge = showBadges ? catalog.badges[app.bid] ?? 0 : 0
                let progress = Int((catalog.progress[app.bid] ?? -1) * 100)
                let hung = app.running.map { catalog.unresponsivePIDs.contains($0.processIdentifier) } ?? false
                let active = (frontID == app.bid || (isWindowListOpen && windowListBundleID == app.bid)) ? 1 : 0
                let windowPart = grouped
                    ? "g\(app.windows.count)"
                    : app.windows.map { "\($0.windowID):\($0.title)" }.joined(separator: "+")
                signatureParts.append(
                    "\(app.bid):\(app.running == nil ? 0 : 1)\(active)\(app.isPinned ? 1 : 0)|\(windowPart)|\(badge)|\(progress)|\(hung ? 1 : 0)|\(grouped ? 1 : 0)"
                )
            }
        }
        let signature = signatureParts.joined(separator: ",")
            + "@\(Int(appStripAvailableWidth))"
            + "|u:\(unpinnedOrder.joined(separator: ","))"
        guard signature != lastItemsSignature else { return }
        lastItemsSignature = signature

        var result: [TaskbarAppItem] = []
        result.reserveCapacity(entries.count)

        for entry in entries {
            switch entry {
            case .folder(let pin, let url):
                let icon = url.map { AppIconCache.icon(forFile: $0.path, size: 64) }
                    ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: pin.name)
                result.append(
                    AppItemFactory.make(
                        bundleIdentifier: pin.id,
                        name: pin.name,
                        icon: icon,
                        url: url,
                        isRunning: false,
                        isActive: false,
                        isPinned: true,
                        isFolder: true
                    )
                )
            case .app(let app):
                let url = app.running?.bundleURL ?? AppIconCache.url(forBundleID: app.bid)
                let name = AppIconCache.displayName(
                    forBundleID: app.bid,
                    url: url,
                    runningName: app.running?.localizedName
                )
                let icon = AppIconCache.icon(
                    forBundleID: app.bid,
                    url: url,
                    fallback: app.running?.icon,
                    size: 64
                )
                let unread = showBadges ? catalog.badges[app.bid] : nil
                let progress = catalog.progress[app.bid]
                let hung = app.running.map { catalog.unresponsivePIDs.contains($0.processIdentifier) } ?? false

                if !grouped, !app.windows.isEmpty {
                    for (index, window) in app.windows.enumerated() {
                        result.append(
                            AppItemFactory.make(
                                bundleIdentifier: app.bid,
                                name: name,
                                icon: icon,
                                url: url,
                                isRunning: true,
                                isActive: (frontID == app.bid || (isWindowListOpen && windowListBundleID == app.bid))
                                    && (frontWindowID == window.windowID || (frontWindowID == nil && index == 0)),
                                isPinned: app.isPinned,
                                processIdentifier: window.pid,
                                windowID: window.windowID,
                                windowIndex: window.axIndex,
                                windowTitle: window.displayTitle(index: index),
                                windowCount: app.windows.count,
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
                            bundleIdentifier: app.bid,
                            name: name,
                            icon: icon,
                            url: url,
                            isRunning: app.running != nil,
                            isActive: frontID == app.bid || (isWindowListOpen && windowListBundleID == app.bid),
                            isPinned: app.isPinned,
                            processIdentifier: app.running?.processIdentifier,
                            windowCount: app.windows.count,
                            badge: unread,
                            badgeIsUnread: unread != nil,
                            progress: progress,
                            isUnresponsive: hung,
                            isGrouped: true
                        )
                    )
                }
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
        if item.isFolder {
            closeOverlays()
            if let pin = pinnedStore.item(id: item.id) {
                pinnedStore.openFolder(pin)
            } else if let url = item.url {
                NSWorkspace.shared.open(url)
            }
            return
        }
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
        let windows = appMonitor.windowCatalog.windows(for: item.bundleIdentifier)
        let current = appMonitor.windowCatalog.frontmostWindowID
        windowListActiveWindowID = current
        windowListHighlightedID = current ?? windows.first?.windowID
        isWindowListOpen = true
    }

    func closeWindowList() {
        isWindowListOpen = false
        windowListBundleID = nil
        windowListHighlightedID = nil
        windowListActiveWindowID = nil
    }

    func moveWindowListHighlight(_ delta: Int) {
        guard let bid = windowListBundleID else { return }
        let windows = appMonitor.windowCatalog.windows(for: bid)
        guard !windows.isEmpty else { return }
        let current = windowListHighlightedID.flatMap { id in
            windows.firstIndex(where: { $0.windowID == id })
        } ?? 0
        let next = (current + delta + windows.count) % windows.count
        windowListHighlightedID = windows[next].windowID
    }

    func confirmWindowListHighlight() {
        guard let bid = windowListBundleID,
              let id = windowListHighlightedID,
              let window = appMonitor.windowCatalog.windows(for: bid).first(where: { $0.windowID == id })
        else { return }
        pickWindow(window)
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

    func toggleShowDesktop() {
        closeOverlays()
        spacesMonitor.toggleShowDesktop()
    }

    func openActivityMonitor() {
        closeOverlays()
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
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
        modifierKeyRemapper.prepareForDisplay()
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
        if item.isFolder { return }
        pinnedStore.pin(item.bundleIdentifier)
    }

    func unpin(_ item: TaskbarAppItem) {
        pinnedStore.unpin(item.id)
    }

    func revealPinnedFolder(_ item: TaskbarAppItem) {
        guard item.isFolder, let pin = pinnedStore.item(id: item.id) else { return }
        pinnedStore.revealFolder(pin)
    }

    func handleTaskbarFileDrop(_ providers: [NSItemProvider], before targetID: String? = nil) -> Bool {
        DroppedFileURLs.load(providers) { [weak self] url in
            guard let self else { return }
            if url.pathExtension.lowercased() == "app",
               let bid = Bundle(url: url)?.bundleIdentifier {
                self.pinnedStore.pin(bid, before: targetID)
            } else if self.pinnedStore.pinFolder(url: url, before: targetID) {
                return
            } else {
                self.favoritesStore.add(url: url)
            }
        }
    }

    func reorderIcons(draggedID: String, onto targetID: String) {
        guard draggedID != targetID else { return }
        let draggedPinned = pinnedStore.isPinned(draggedID)
        let targetPinned = pinnedStore.isPinned(targetID)

        if draggedPinned, targetPinned {
            pinnedStore.reorder(draggedID: draggedID, targetID: targetID)
            return
        }
        if !draggedPinned, targetPinned {
            pinnedStore.pin(draggedID, before: targetID)
            return
        }
        if draggedPinned, !targetPinned {
            pinnedStore.moveToEnd(draggedID)
            return
        }

        var order = currentUnpinnedIDs()
        if !order.contains(draggedID) { order.append(draggedID) }
        if !order.contains(targetID) { order.append(targetID) }
        guard let from = order.firstIndex(of: draggedID),
              let to = order.firstIndex(of: targetID)
        else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        unpinnedOrder = order
        lastItemsSignature = ""
        rebuildItems()
    }

    private func currentUnpinnedIDs() -> [String] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard !item.isPinned, !item.isFolder else { return nil }
            if seen.contains(item.bundleIdentifier) { return nil }
            seen.insert(item.bundleIdentifier)
            return item.bundleIdentifier
        }
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
