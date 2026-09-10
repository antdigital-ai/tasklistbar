import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class TaskbarController: NSObject {
    static var barHeight: CGFloat { TaskbarMetrics.barHeight }

    private let viewModel: TaskbarViewModel
    private var panel: NSPanel?
    private var startMenuPanel: NSPanel?
    private var modifierKeysPanel: NSPanel?
    private var calendarPanel: NSPanel?
    private var settingsPanel: NSPanel?
    private var permissionsPanel: NSPanel?
    private var windowListPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var hotkeyCenter = HotkeyCenter()
    private let windowAvoider = WindowAvoider()
    private var cancellables = Set<AnyCancellable>()
    private var spaceAttachTask: Task<Void, Never>?
    private var suppressOutsideClose = false

    init(
        appMonitor: AppMonitor,
        pinnedStore: PinnedAppsStore,
        startMenuCatalog: StartMenuCatalog,
        modifierKeyRemapper: ModifierKeyRemapper,
        appSettings: AppSettings
    ) {
        self.viewModel = TaskbarViewModel(
            appMonitor: appMonitor,
            pinnedStore: pinnedStore,
            startMenuCatalog: startMenuCatalog,
            modifierKeyRemapper: modifierKeyRemapper,
            appSettings: appSettings,
            batteryMonitor: BatteryMonitor(),
            spacesMonitor: SpacesMonitor(),
            bluetoothMonitor: BluetoothMonitor(),
            volumeMonitor: VolumeMonitor(),
            favoritesStore: FavoritesStore()
        )
        super.init()
    }

    func show() {
        createStatusItem()
        createTaskbarPanel()
        showTaskbarOnActiveDesktop()
        observeScreens()
        observeClicksOutside()
        observeHotkeys()
        observeWindowAvoidance()
        observeBarSize()
        observeFullscreenSpace()
        viewModel.startTrayMonitors()
        prewarmStartMenu()
        presentPermissionsIfNeeded()

        viewModel.$isStartMenuOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncStartMenuVisibility()
            }
            .store(in: &cancellables)

        viewModel.$isModifierKeysOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncModifierKeysVisibility()
            }
            .store(in: &cancellables)

        viewModel.$isCalendarOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncCalendarVisibility()
            }
            .store(in: &cancellables)

        viewModel.$isCalendarExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCalendarHeight()
            }
            .store(in: &cancellables)

        viewModel.$isCalendarAgendaExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCalendarHeight()
            }
            .store(in: &cancellables)

        viewModel.$isSettingsOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncSettingsVisibility()
            }
            .store(in: &cancellables)

        viewModel.$isPermissionsOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncPermissionsVisibility()
            }
            .store(in: &cancellables)

        viewModel.$isWindowListOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncWindowListVisibility()
            }
            .store(in: &cancellables)
    }

    /// Build the start-menu panel ahead of the first click so opening feels instant.
    private func prewarmStartMenu() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            self.createStartMenuPanelIfNeeded()
            self.layoutPanels()
            guard let panel = self.startMenuPanel else { return }
            // Force Liquid Glass to compile while the menu is still invisible.
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !self.viewModel.isStartMenuOpen else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "menubar.dock.rectangle",
                accessibilityDescription: "KeelBar"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "KeelBar"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusItem("打开开始菜单", symbol: "square.grid.2x2", action: #selector(statusOpenStartMenu)))
        menu.addItem(statusItem("设置", symbol: "gearshape", action: #selector(statusOpenSettings), key: ","))
        menu.addItem(statusItem("权限", symbol: "lock.shield", action: #selector(statusOpenPermissions)))
        menu.addItem(statusItem("修饰键设置", symbol: "keyboard", action: #selector(statusOpenModifierKeys)))
        menu.addItem(.separator())
        let launchItem = statusItem("开机时启动", symbol: "power", action: #selector(statusToggleLaunchAtLogin))
        launchItem.tag = StatusMenuTag.launchAtLogin.rawValue
        menu.addItem(launchItem)
        let dockItem = statusItem("隐藏系统 Dock", symbol: "menubar.dock.rectangle", action: #selector(statusToggleHideDock))
        dockItem.tag = StatusMenuTag.hideDock.rawValue
        menu.addItem(dockItem)

        let themeMenu = NSMenu()
        for appearance in AppAppearance.allCases {
            let themeOption = statusItem(
                appearance.title,
                symbol: appearance.systemImage,
                action: #selector(statusSetAppearance(_:))
            )
            themeOption.representedObject = appearance.rawValue
            themeOption.tag = StatusMenuTag.appearanceBase.rawValue
            themeMenu.addItem(themeOption)
        }
        let themeItem = statusItem("主题", symbol: "circle.lefthalf.filled", action: nil)
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        let sizeMenu = NSMenu()
        for size in TaskbarSize.allCases {
            let sizeOption = statusItem(
                "\(size.title)（\(Int(size.barHeight))pt）",
                symbol: "rectangle.bottomhalf.inset.filled",
                action: #selector(statusSetBarSize(_:))
            )
            sizeOption.representedObject = size.rawValue
            sizeMenu.addItem(sizeOption)
        }
        let sizeItem = statusItem("任务栏大小", symbol: "arrow.up.left.and.arrow.down.right", action: nil)
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let groupingMenu = NSMenu()
        for grouping in WindowGrouping.allCases {
            let option = statusItem(
                grouping.title,
                symbol: "rectangle.split.3x1",
                action: #selector(statusSetGrouping(_:))
            )
            option.representedObject = grouping.rawValue
            groupingMenu.addItem(option)
        }
        let groupingItem = statusItem("窗口分组", symbol: "rectangle.split.3x1", action: nil)
        groupingItem.submenu = groupingMenu
        menu.addItem(groupingItem)
        menu.addItem(.separator())
        menu.addItem(statusItem("刷新开始菜单缓存", symbol: "arrow.clockwise", action: #selector(statusRefreshStartMenu)))
        menu.addItem(statusItem("显示任务栏", symbol: "rectangle.bottomhalf.inset.filled", action: #selector(statusShowTaskbar)))
        menu.addItem(statusItem("打开日志文件夹", symbol: "folder", action: #selector(statusOpenLogs)))
        menu.addItem(.separator())
        menu.addItem(statusItem("退出 KeelBar", symbol: "power", action: #selector(statusQuit), key: "q"))
        statusItem = item
        item.menu = menu
    }

    private func statusItem(_ title: String, symbol: String, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == nil ? nil : self
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            item.image = image
        }
        return item
    }

    private enum StatusMenuTag: Int {
        case launchAtLogin = 101
        case hideDock = 102
        case appearanceBase = 200
    }

    @objc private func statusOpenStartMenu() {
        viewModel.closeOverlays()
        viewModel.isStartMenuOpen = true
        viewModel.startMenuCatalog.refresh(force: false)
    }

    @objc private func statusOpenSettings() {
        viewModel.openSettings()
    }

    @objc private func statusOpenPermissions() {
        viewModel.openPermissions()
    }

    @objc private func statusToggleLaunchAtLogin() {
        viewModel.appSettings.setLaunchAtLogin(!viewModel.appSettings.launchAtLogin)
    }

    @objc private func statusToggleHideDock() {
        viewModel.appSettings.setHideDock(!viewModel.appSettings.hideDock)
    }

    @objc private func statusSetAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let appearance = AppAppearance(rawValue: raw)
        else { return }
        viewModel.appSettings.setAppearance(appearance)
    }

    @objc private func statusSetBarSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = TaskbarSize(rawValue: raw)
        else { return }
        viewModel.appSettings.setBarSize(size)
    }

    @objc private func statusSetGrouping(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let grouping = WindowGrouping(rawValue: raw)
        else { return }
        viewModel.appSettings.setWindowGrouping(grouping)
    }

    @objc private func statusRefreshStartMenu() {
        viewModel.startMenuCatalog.refresh(force: true)
    }

    @objc private func statusOpenModifierKeys() {
        viewModel.openModifierKeysSettings()
    }

    @objc private func statusShowTaskbar() {
        guard !viewModel.spacesMonitor.isFullscreenSpace,
              !viewModel.spacesMonitor.looksFullscreenNow()
        else { return }
        showTaskbarOnActiveDesktop()
    }

    @objc private func statusOpenLogs() {
        AppLog.openInFinder()
    }

    @objc private func statusQuit() {
        NSApp.terminate(nil)
    }

    private func createTaskbarPanel() {
        let glass = GlassPanelFactory.wrap(
            ThemedRoot(settings: viewModel.appSettings) {
                TaskbarRootView(viewModel: viewModel)
            },
            lockArrowCursor: true
        )

        let panel = TaskbarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // High enough to sit above Dock and third-party bars like uBar.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        // Stay on the current desktop only. Joining all spaces would flash the
        // bar onto a fullscreen Space before we can hide it.
        panel.collectionBehavior = [.stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        applyBarHeightConstraints(to: panel)
        panel.contentView = glass
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func createStartMenuPanelIfNeeded() {
        if startMenuPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            ThemedRoot(settings: viewModel.appSettings) {
                StartMenuView(viewModel: viewModel)
            },
            cornerRadius: 20
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = glass

        startMenuPanel = panel
    }

    private func createModifierKeysPanelIfNeeded() {
        if modifierKeysPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            ThemedRoot(settings: viewModel.appSettings) {
                ModifierKeysSettingsView(remapper: viewModel.modifierKeyRemapper) { [weak self] in
                    self?.viewModel.closeModifierKeysSettings()
                }
            },
            cornerRadius: 20
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: ModifierKeysSettingsView.Metrics.width, height: ModifierKeysSettingsView.Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        glass.autoresizingMask = [.width, .height]
        panel.contentView = glass

        modifierKeysPanel = panel
    }

    private func createCalendarPanelIfNeeded() {
        if calendarPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            CalendarPanelRoot(
                settings: viewModel.appSettings,
                viewModel: viewModel
            ),
            cornerRadius: CalendarPreviewView.Metrics.corner
        )

        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: CalendarPreviewView.Metrics.width,
                height: CalendarPreviewView.Metrics.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = glass

        calendarPanel = panel
    }

    private func createSettingsPanelIfNeeded() {
        if settingsPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            ThemedRoot(settings: viewModel.appSettings) {
                AppSettingsView(
                    settings: viewModel.appSettings,
                    permissionCenter: viewModel.permissionCenter,
                    onOpenPermissions: { [weak self] in
                        self?.viewModel.openPermissions()
                    },
                    onOpenModifierKeys: { [weak self] in
                        self?.viewModel.openModifierKeysSettings()
                    },
                    onClose: { [weak self] in
                        self?.viewModel.closeSettings()
                    }
                )
            },
            cornerRadius: 20
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: AppSettingsView.Metrics.width, height: AppSettingsView.Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = glass

        settingsPanel = panel
    }

    private func createPermissionsPanelIfNeeded() {
        if permissionsPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            ThemedRoot(settings: viewModel.appSettings) {
                PermissionsView(center: viewModel.permissionCenter) { [weak self] in
                    self?.viewModel.closePermissions()
                }
            },
            cornerRadius: 20
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PermissionsView.Metrics.width, height: PermissionsView.Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = glass

        permissionsPanel = panel
    }

    private func createWindowListPanelIfNeeded() {
        if windowListPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            ThemedRoot(settings: viewModel.appSettings) {
                WindowListView(
                    viewModel: viewModel,
                    catalog: viewModel.appMonitor.windowCatalog
                )
            },
            cornerRadius: 12
        )

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: WindowListView.panelWidth, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = glass

        windowListPanel = panel
    }

    private func layoutPanels() {
        if viewModel.spacesMonitor.isFullscreenSpace || viewModel.spacesMonitor.looksFullscreenNow() {
            hideTaskbarForFullscreen()
            return
        }
        repositionTaskbarIfNeeded()
        if panel?.isVisible == true {
            panel?.alphaValue = 1
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                layoutOverlays(on: screen, animated: false)
            }
        }
    }

    private func showTaskbarOnActiveDesktop() {
        guard let panel else { return }
        guard !viewModel.spacesMonitor.isFullscreenSpace,
              !viewModel.spacesMonitor.looksFullscreenNow()
        else {
            hideTaskbarForFullscreen()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let target = taskbarFrame(on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.collectionBehavior = [.moveToActiveSpace, .stationary]
            if !Self.framesAlmostEqual(panel.frame, target) {
                panel.setFrame(target, display: true)
            }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.collectionBehavior = [.stationary]
        }
        layoutOverlays(on: screen, animated: false)
    }

    private func repositionTaskbarIfNeeded() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let target = taskbarFrame(on: screen)
        guard !Self.framesAlmostEqual(panel.frame, target) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.setFrame(target, display: true)
        }
    }

    private static func framesAlmostEqual(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5
            && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5
            && abs(a.height - b.height) < 0.5
    }

    private func taskbarFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width,
            height: Self.barHeight
        )
    }

    private func layoutOverlays(on screen: NSScreen, animated: Bool) {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let bar = Self.barHeight
        let apply: (NSPanel, NSRect) -> Void = { panel, rect in
            if animated {
                panel.animator().setFrame(rect, display: true)
            } else {
                panel.setFrame(rect, display: true)
            }
        }

        if let start = startMenuPanel {
            let menuHeight = min(560, max(360, visible.height - 80))
            apply(start, NSRect(
                x: frame.minX + 8,
                y: frame.minY + bar + 8,
                width: 420,
                height: menuHeight
            ))
        }
        if let modifiers = modifierKeysPanel {
            apply(modifiers, modifierKeysTargetFrame())
        }
        if let calendar = calendarPanel {
            apply(calendar, calendarTargetFrame())
        }
        if let settings = settingsPanel {
            apply(settings, settingsTargetFrame())
        }
        if let permissions = permissionsPanel {
            apply(permissions, permissionsTargetFrame())
        }
        if let list = windowListPanel {
            apply(list, windowListTargetFrame())
        }
    }

    private func syncStartMenuVisibility() {
        if viewModel.isStartMenuOpen {
            createStartMenuPanelIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            animateStartMenu(show: true) { [weak self] in
                guard let self, self.viewModel.isStartMenuOpen else { return }
                self.startMenuPanel?.makeKeyAndOrderFront(nil)
                self.focusFirstTextField(in: self.startMenuPanel)
            }
        } else {
            animateStartMenu(show: false)
        }
    }

    private func syncModifierKeysVisibility() {
        if viewModel.isModifierKeysOpen {
            hideOverlayImmediately(settingsPanel)
            hideOverlayImmediately(permissionsPanel)
            hideOverlayImmediately(startMenuPanel)
            createModifierKeysPanelIfNeeded()
            ignoreOutsideClick()
            animatePanel(
                modifierKeysPanel,
                show: true,
                target: modifierKeysTargetFrame()
            )
            NSApp.activate(ignoringOtherApps: true)
        } else {
            animatePanel(
                modifierKeysPanel,
                show: false,
                target: modifierKeysTargetFrame()
            )
        }
    }

    private func syncCalendarVisibility() {
        if viewModel.isCalendarOpen {
            createCalendarPanelIfNeeded()
            animatePanel(
                calendarPanel,
                show: true,
                target: calendarTargetFrame()
            )
            NSApp.activate(ignoringOtherApps: true)
        } else {
            animatePanel(
                calendarPanel,
                show: false,
                target: calendarTargetFrame()
            )
        }
    }

    private func syncWindowListVisibility() {
        if viewModel.isWindowListOpen {
            createWindowListPanelIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            animatePanel(
                windowListPanel,
                show: true,
                target: windowListTargetFrame()
            ) { [weak self] in
                guard let self, self.viewModel.isWindowListOpen else { return }
                self.windowListPanel?.makeKeyAndOrderFront(nil)
            }
            windowListPanel?.makeKeyAndOrderFront(nil)
        } else {
            animatePanel(
                windowListPanel,
                show: false,
                target: windowListTargetFrame()
            )
        }
    }

    private func syncSettingsVisibility() {
        if viewModel.isSettingsOpen {
            hideOverlayImmediately(permissionsPanel)
            createSettingsPanelIfNeeded()
            animatePanel(
                settingsPanel,
                show: true,
                target: settingsTargetFrame()
            )
            NSApp.activate(ignoringOtherApps: true)
        } else {
            animatePanel(
                settingsPanel,
                show: false,
                target: settingsTargetFrame()
            )
        }
    }

    private func syncPermissionsVisibility() {
        if viewModel.isPermissionsOpen {
            hideOverlayImmediately(settingsPanel)
            hideOverlayImmediately(startMenuPanel)
            hideOverlayImmediately(modifierKeysPanel)
            createPermissionsPanelIfNeeded()
            ignoreOutsideClick()
            animatePanel(
                permissionsPanel,
                show: true,
                target: permissionsTargetFrame()
            )
            NSApp.activate(ignoringOtherApps: true)
        } else {
            animatePanel(
                permissionsPanel,
                show: false,
                target: permissionsTargetFrame()
            )
        }
    }

    private func animateStartMenu(show: Bool, onShown: (() -> Void)? = nil) {
        guard let panel = startMenuPanel else { return }
        let target = startMenuTargetFrame()
        if panel.frame != target {
            panel.setFrame(target, display: false)
        }

        guard let content = panel.contentView, let layer = content.layer else {
            animatePanel(panel, show: show, target: target, duration: TaskbarMotion.Panel.startMenuShowDuration, onShown: onShown)
            return
        }

        resetLayerGeometry(layer)

        if show {
            panel.alphaValue = 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            CATransaction.commit()
            panel.orderFrontRegardless()
            content.layoutSubtreeIfNeeded()
            let hidden = startMenuPopTransform(
                scale: TaskbarMotion.Panel.startMenuFromScale,
                in: content,
                layer: layer
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = hidden
            layer.opacity = 1
            CATransaction.commit()

            animateStartMenuLayer(
                layer,
                fromTransform: hidden,
                fromOpacity: 1,
                toTransform: CATransform3DIdentity,
                toOpacity: 1,
                duration: TaskbarMotion.Panel.startMenuShowDuration,
                timing: TaskbarMotion.Panel.startMenuTiming
            ) {
                DispatchQueue.main.async { onShown?() }
            }
        } else if panel.isVisible {
            let hidden = startMenuPopTransform(
                scale: TaskbarMotion.Panel.startMenuFromScale,
                in: content,
                layer: layer
            )
            let fromTransform = layer.presentation()?.transform ?? CATransform3DIdentity
            let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
            animateStartMenuLayer(
                layer,
                fromTransform: fromTransform,
                fromOpacity: fromOpacity,
                toTransform: hidden,
                toOpacity: 0,
                duration: TaskbarMotion.Panel.startMenuHideDuration,
                timing: TaskbarMotion.Panel.startMenuHideTiming,
                fadeBeginFraction: TaskbarMotion.Panel.startMenuFadeBegin,
                fadeTiming: TaskbarMotion.Panel.startMenuFadeTiming
            ) { [weak panel] in
                guard let panel else { return }
                panel.orderOut(nil)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                panel.contentView?.layer?.transform = CATransform3DIdentity
                panel.contentView?.layer?.opacity = 1
                CATransaction.commit()
            }
        }
    }

    /// NSView-hosted layers suppress implicit transform animation, so the
    /// scale must be an explicit CAAnimation or it jumps with no in-between.
    private func animateStartMenuLayer(
        _ layer: CALayer,
        fromTransform: CATransform3D,
        fromOpacity: Float,
        toTransform: CATransform3D,
        toOpacity: Float,
        duration: TimeInterval,
        timing: CAMediaTimingFunction,
        fadeBeginFraction: Double = 0,
        fadeTiming: CAMediaTimingFunction? = nil,
        completion: (() -> Void)?
    ) {
        layer.removeAnimation(forKey: "startMenuPop")

        let pop = CABasicAnimation(keyPath: "transform")
        pop.fromValue = NSValue(caTransform3D: fromTransform)
        pop.toValue = NSValue(caTransform3D: toTransform)
        pop.duration = duration
        pop.timingFunction = timing

        var animations: [CAAnimation] = [pop]
        if fromOpacity != toOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = toOpacity
            fade.beginTime = duration * fadeBeginFraction
            fade.duration = max(0.001, duration * (1 - fadeBeginFraction))
            fade.timingFunction = fadeTiming ?? timing
            fade.fillMode = .both
            animations.append(fade)
        }

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            DispatchQueue.main.async {
                layer.removeAnimation(forKey: "startMenuPop")
                layer.transform = toTransform
                layer.opacity = toOpacity
                completion?()
            }
        }
        layer.add(group, forKey: "startMenuPop")
        layer.transform = toTransform
        layer.opacity = toOpacity
        CATransaction.commit()
    }

    /// Scale around the menu's bottom-left. Layer transforms are relative to
    /// `anchorPoint` (the center), so the pivot must be converted out of bounds space.
    private func startMenuPopTransform(scale: CGFloat, in view: NSView, layer: CALayer) -> CATransform3D {
        let bounds = layer.bounds.width > 1 ? layer.bounds : view.bounds
        let flipped = view.isFlipped || layer.isGeometryFlipped
        let pivot = CGPoint(
            x: bounds.minX,
            y: flipped ? bounds.maxY : bounds.minY
        )
        let anchor = CGPoint(
            x: bounds.minX + layer.anchorPoint.x * bounds.width,
            y: bounds.minY + layer.anchorPoint.y * bounds.height
        )
        let px = pivot.x - anchor.x
        let py = pivot.y - anchor.y

        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, px, py, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -px, -py, 0)
        return transform
    }

    private func resetLayerGeometry(_ layer: CALayer) {
        let center = CGPoint(x: 0.5, y: 0.5)
        let old = layer.anchorPoint
        if abs(old.x - center.x) > 0.0001 || abs(old.y - center.y) > 0.0001 {
            layer.anchorPoint = center
            var position = layer.position
            position.x += (center.x - old.x) * layer.bounds.width
            position.y += (center.y - old.y) * layer.bounds.height
            layer.position = position
        }
        layer.shouldRasterize = false
    }

    private func animatePanel(
        _ panel: NSPanel?,
        show: Bool,
        target: NSRect,
        duration: TimeInterval = TaskbarMotion.Panel.showDuration,
        onShown: (() -> Void)? = nil
    ) {
        guard let panel else { return }
        resetContentLift(panel)
        if panel.frame != target {
            panel.setFrame(target, display: false)
        }

        let timing = show ? TaskbarMotion.Panel.showTiming : TaskbarMotion.Panel.hideTiming

        if show {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = timing
                panel.animator().alphaValue = 1
            }, completionHandler: {
                DispatchQueue.main.async {
                    onShown?()
                }
            })
        } else if panel.isVisible {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = timing
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        }
    }

    private func resetContentLift(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func startMenuTargetFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let menuHeight = min(560, max(360, visible.height - 80))
        return NSRect(
            x: frame.minX + 8,
            y: frame.minY + Self.barHeight + 8,
            width: 420,
            height: menuHeight
        )
    }

    private func modifierKeysTargetFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.frame
        return NSRect(
            x: frame.minX + 8,
            y: frame.minY + Self.barHeight + 8,
            width: ModifierKeysSettingsView.Metrics.width,
            height: ModifierKeysSettingsView.Metrics.height
        )
    }

    private func hideOverlayImmediately(_ panel: NSPanel?) {
        guard let panel, panel.isVisible else { return }
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    private func ignoreOutsideClick() {
        suppressOutsideClose = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressOutsideClose = false
        }
    }

    private func calendarTargetFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.frame
        let height = CalendarPreviewView.Metrics.panelHeight(
            monthExpanded: viewModel.isCalendarExpanded,
            agendaExpanded: viewModel.isCalendarAgendaExpanded
        )
        return NSRect(
            x: frame.maxX - CalendarPreviewView.Metrics.width - 10,
            y: frame.minY + Self.barHeight + 10,
            width: CalendarPreviewView.Metrics.width,
            height: height
        )
    }

    private func updateCalendarHeight() {
        guard viewModel.isCalendarOpen, let panel = calendarPanel else { return }
        let target = calendarTargetFrame()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TaskbarMotion.Panel.resizeDuration
            context.timingFunction = TaskbarMotion.Panel.resizeTiming
            panel.animator().setFrame(target, display: true)
        }
    }

    private func windowListTargetFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.frame
        let count = viewModel.windowListBundleID.map { viewModel.appMonitor.windowCatalog.windows(for: $0).count } ?? 1
        let width = WindowListView.panelWidth
        let height = WindowListView.panelHeight(count: count)
        var x = viewModel.windowListAnchorX - 12
        x = max(frame.minX + 8, min(x, frame.maxX - width - 8))
        return NSRect(
            x: x,
            y: frame.minY + Self.barHeight + 8,
            width: width,
            height: height
        )
    }

    private func settingsTargetFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.frame
        return NSRect(
            x: frame.minX + 8,
            y: frame.minY + Self.barHeight + 8,
            width: AppSettingsView.Metrics.width,
            height: AppSettingsView.Metrics.height
        )
    }

    private func permissionsTargetFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.frame
        return NSRect(
            x: frame.minX + 8,
            y: frame.minY + Self.barHeight + 8,
            width: PermissionsView.Metrics.width,
            height: PermissionsView.Metrics.height
        )
    }

    private func presentPermissionsIfNeeded() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            self.viewModel.presentPermissionsIfNeeded()
        }
    }

    private func observeFullscreenSpace() {
        viewModel.spacesMonitor.onFullscreenDetected = { [weak self] in
            self?.hideTaskbarForFullscreen()
        }
        viewModel.spacesMonitor.onActiveSpaceChanged = { [weak self] in
            self?.syncTaskbarToActiveSpace()
        }
        viewModel.spacesMonitor.$isFullscreenSpace
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] fullscreen in
                self?.setTaskbarHiddenForFullscreen(fullscreen)
            }
            .store(in: &cancellables)
    }

    private func syncTaskbarToActiveSpace() {
        spaceAttachTask?.cancel()
        if viewModel.spacesMonitor.looksFullscreenNow() || viewModel.spacesMonitor.isFullscreenSpace {
            hideTaskbarForFullscreen()
            return
        }
        // Wait for SkyLight to settle so we do not follow a new fullscreen Space.
        spaceAttachTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.viewModel.spacesMonitor.looksFullscreenNow(),
                  !self.viewModel.spacesMonitor.isFullscreenSpace
            else { return }
            self.showTaskbarOnActiveDesktop()
        }
    }

    private func setTaskbarHiddenForFullscreen(_ hidden: Bool) {
        if hidden || viewModel.spacesMonitor.looksFullscreenNow() {
            hideTaskbarForFullscreen()
        } else {
            showTaskbarOnActiveDesktop()
        }
    }

    private func hideTaskbarForFullscreen() {
        spaceAttachTask?.cancel()
        viewModel.closeOverlays()
        guard let panel else { return }
        panel.alphaValue = 0
        panel.collectionBehavior = [.stationary]
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.viewModel.spacesMonitor.probeAndApplyFullscreen(reason: "observeScreens")
                if self.viewModel.spacesMonitor.isFullscreenSpace
                    || self.viewModel.spacesMonitor.looksFullscreenNow() {
                    self.hideTaskbarForFullscreen()
                    return
                }
                self.layoutPanels()
            }
        }
    }

    private func observeHotkeys() {
        hotkeyCenter.onAction = { [weak self] action in
            self?.handleHotkey(action)
        }
        hotkeyCenter.setChord(viewModel.appSettings.startMenuHotkey, for: .startMenu)
        hotkeyCenter.setChord(viewModel.appSettings.calendarHotkey, for: .calendar)

        viewModel.appSettings.$startMenuHotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] chord in
                self?.hotkeyCenter.setChord(chord, for: .startMenu)
            }
            .store(in: &cancellables)

        viewModel.appSettings.$calendarHotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] chord in
                self?.hotkeyCenter.setChord(chord, for: .calendar)
            }
            .store(in: &cancellables)

        viewModel.appSettings.$isRecordingHotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] recording in
                if recording {
                    self?.hotkeyCenter.suspend()
                } else {
                    self?.hotkeyCenter.resume()
                }
            }
            .store(in: &cancellables)

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleLocalKey(event) ?? event
        }
    }

    private func observeWindowAvoidance() {
        if viewModel.appSettings.avoidOverlappingWindows {
            windowAvoider.setEnabled(true)
            windowAvoider.start()
        }
        viewModel.appSettings.$avoidOverlappingWindows
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.windowAvoider.setEnabled(enabled)
                if enabled {
                    self.windowAvoider.start()
                    if !self.windowAvoider.isTrusted {
                        self.viewModel.openPermissions()
                    }
                } else {
                    self.windowAvoider.stop()
                }
            }
            .store(in: &cancellables)
    }

    private func observeBarSize() {
        viewModel.appSettings.$barSize
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.animateBarSize()
            }
            .store(in: &cancellables)
    }

    private func animateBarSize() {
        guard let panel,
              let screen = NSScreen.main ?? NSScreen.screens.first
        else {
            layoutPanels()
            return
        }

        let targetHeight = TaskbarMetrics.barHeight
        let currentHeight = panel.frame.height
        let low = min(currentHeight, targetHeight)
        let high = max(currentHeight, targetHeight)
        panel.minSize = NSSize(width: 0, height: low)
        panel.maxSize = NSSize(width: 10_000, height: high)
        panel.contentMinSize = NSSize(width: 0, height: low)
        panel.contentMaxSize = NSSize(width: 10_000, height: high)

        if let taskbar = panel as? TaskbarPanel {
            taskbar.locksHeight = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = TaskbarMotion.Panel.resizeDuration
            context.timingFunction = TaskbarMotion.Panel.resizeTiming
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(taskbarFrame(on: screen), display: true)
            layoutOverlays(on: screen, animated: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                if let taskbar = panel as? TaskbarPanel {
                    taskbar.locksHeight = true
                }
                self.applyBarHeightConstraints(to: panel)
                if self.viewModel.appSettings.avoidOverlappingWindows {
                    self.windowAvoider.refresh()
                }
            }
        })
    }

    private func applyBarHeightConstraints(to panel: NSPanel) {
        let height = TaskbarMetrics.barHeight
        panel.minSize = NSSize(width: 0, height: height)
        panel.maxSize = NSSize(width: 10_000, height: height)
        panel.contentMinSize = NSSize(width: 0, height: height)
        panel.contentMaxSize = NSSize(width: 10_000, height: height)
    }

    private func handleHotkey(_ action: HotkeyCenter.Action) {
        switch action {
        case .startMenu:
            AppLog.info("快捷键：开始菜单", category: "hotkey")
            viewModel.toggleStartMenu()
        case .calendar:
            AppLog.info("快捷键：日历", category: "hotkey")
            viewModel.toggleCalendarPreview()
        }
    }

    private func handleLocalKey(_ event: NSEvent) -> NSEvent? {
        if viewModel.appSettings.isRecordingHotkey {
            return event
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if event.keyCode == 53, modifiers.isEmpty {
            if viewModel.isCalendarAgendaExpanded {
                viewModel.isCalendarAgendaExpanded = false
                return nil
            }
            if viewModel.hasOpenOverlay {
                viewModel.closeOverlays()
                return nil
            }
            return event
        }

        if viewModel.isWindowListOpen, modifiers.isEmpty {
            switch event.keyCode {
            case 125:
                viewModel.moveWindowListHighlight(1)
                return nil
            case 126:
                viewModel.moveWindowListHighlight(-1)
                return nil
            case 36, 76:
                viewModel.confirmWindowListHighlight()
                return nil
            default:
                break
            }
        }

        guard viewModel.isCalendarOpen, !viewModel.isSettingsOpen, !viewModel.isPermissionsOpen, modifiers.isEmpty else {
            return event
        }

        switch event.keyCode {
        case 123:
            viewModel.requestCalendarShift(-1)
            return nil
        case 124:
            viewModel.requestCalendarShift(1)
            return nil
        case 126:
            if !viewModel.isCalendarExpanded {
                viewModel.toggleCalendarMonth()
            }
            return nil
        case 125:
            if viewModel.isCalendarExpanded {
                viewModel.toggleCalendarMonth()
            }
            return nil
        default:
            return event
        }
    }

    private func observeClicksOutside() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleMouseDown()
        }
    }

    private func handleMouseDown() {
        guard viewModel.hasOpenOverlay, !suppressOutsideClose else { return }
        let location = NSEvent.mouseLocation
        let inBar = panel?.frame.contains(location) == true

        if viewModel.isStartMenuOpen {
            let inStart = startMenuPanel?.frame.contains(location) == true
            if !inStart && !inBar {
                viewModel.closeStartMenu()
            }
        }

        if viewModel.isModifierKeysOpen {
            let inModifiers = modifierKeysPanel?.frame.contains(location) == true
            if !inModifiers && !inBar {
                viewModel.closeModifierKeysSettings()
            }
        }

        if viewModel.isCalendarOpen {
            let inCalendar = calendarPanel?.frame.contains(location) == true
            if !inCalendar && !inBar {
                viewModel.closeCalendarPreview()
            }
        }

        if viewModel.isSettingsOpen {
            let inSettings = settingsPanel?.frame.contains(location) == true
            if !inSettings && !inBar {
                viewModel.closeSettings()
            }
        }

        if viewModel.isPermissionsOpen {
            let inPermissions = permissionsPanel?.frame.contains(location) == true
            if !inPermissions && !inBar {
                viewModel.closePermissions()
            }
        }

        if viewModel.isWindowListOpen {
            let inList = windowListPanel?.frame.contains(location) == true
            if !inList && !inBar {
                viewModel.closeWindowList()
            }
        }
    }

    private func focusFirstTextField(in panel: NSPanel?) {
        guard let panel else { return }
        DispatchQueue.main.async {
            guard panel.isVisible else { return }
            guard let field = Self.firstEditableTextField(in: panel.contentView) else { return }
            if panel.firstResponder !== field {
                panel.makeFirstResponder(field)
            }
        }
    }

    private static func firstEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = firstEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        animationBehavior = .none
    }
}

final class TaskbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var locksHeight = true

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        lockedFrame(frameRect, preferredScreen: screen)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(lockedFrame(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(lockedFrame(frameRect), display: displayFlag, animate: false)
    }

    private func lockedFrame(_ frameRect: NSRect, preferredScreen: NSScreen? = nil) -> NSRect {
        var rect = frameRect
        if locksHeight {
            rect.size.height = TaskbarMetrics.barHeight
        }
        let target = preferredScreen
            ?? NSScreen.screens.first(where: { abs($0.frame.minX - rect.minX) < 2 && $0.frame.width + 2 >= rect.width })
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.minY + 1)) })
        if let target {
            rect.origin.y = target.frame.minY
        }
        return rect
    }
}

extension TaskbarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = menu.item(withTag: StatusMenuTag.launchAtLogin.rawValue) {
            item.state = viewModel.appSettings.launchAtLogin ? .on : .off
        }
        if let item = menu.item(withTag: StatusMenuTag.hideDock.rawValue) {
            item.state = viewModel.appSettings.hideDock ? .on : .off
        }
        if let themeItem = menu.items.first(where: { $0.submenu != nil && $0.title == "主题" }) {
            for item in themeItem.submenu?.items ?? [] {
                let raw = item.representedObject as? String
                item.state = raw == viewModel.appSettings.appearance.rawValue ? .on : .off
            }
        }
        if let sizeItem = menu.items.first(where: { $0.submenu != nil && $0.title == "任务栏大小" }) {
            for item in sizeItem.submenu?.items ?? [] {
                let raw = item.representedObject as? String
                item.state = raw == viewModel.appSettings.barSize.rawValue ? .on : .off
            }
        }
        if let groupingItem = menu.items.first(where: { $0.submenu != nil && $0.title == "窗口分组" }) {
            for item in groupingItem.submenu?.items ?? [] {
                let raw = item.representedObject as? String
                item.state = raw == viewModel.appSettings.windowGrouping.rawValue ? .on : .off
            }
        }
    }
}
