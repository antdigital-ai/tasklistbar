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
    @Published var showsAllApps = false
    @Published var calendarNavigate = CalendarNavigate()

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
        volumeMonitor: VolumeMonitor
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
        self.isCalendarExpanded = appSettings.calendarExpanded

        appMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        pinnedStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }
            .store(in: &cancellables)

        $isCalendarExpanded
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.appSettings.setCalendarExpanded(expanded)
                AppLog.info(expanded ? "日历展开为整月" : "日历收起为一周", category: "calendar")
            }
            .store(in: &cancellables)

        rebuildItems()
        // Warm start-menu cache in background after launch.
        startMenuCatalog.refresh(force: false)
    }

    func startTrayMonitors() {
        batteryMonitor.start()
        spacesMonitor.start()
        bluetoothMonitor.start()
        volumeMonitor.start()
        clockModel.start()
        calendarStore.start()
        weatherStore.start()
    }

    func stopTrayMonitors() {
        batteryMonitor.stop()
        spacesMonitor.stop()
        bluetoothMonitor.stop()
        volumeMonitor.stop()
        clockModel.stop()
        calendarStore.stop()
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
        closeOverlays()
        appMonitor.activateOrLaunch(item: item)
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
        startMenuCatalog.searchText = ""
        isSettingsOpen = true
    }

    func closeSettings() {
        appSettings.isRecordingHotkey = false
        isSettingsOpen = false
    }

    func closeOverlays() {
        isStartMenuOpen = false
        isModifierKeysOpen = false
        isCalendarOpen = false
        isSettingsOpen = false
        isCalendarAgendaExpanded = false
        appSettings.isRecordingHotkey = false
        showsAllApps = false
        startMenuCatalog.selectedCategory = nil
        startMenuCatalog.searchText = ""
    }

    var hasOpenOverlay: Bool {
        isStartMenuOpen || isModifierKeysOpen || isCalendarOpen || isSettingsOpen || isCalendarAgendaExpanded
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
