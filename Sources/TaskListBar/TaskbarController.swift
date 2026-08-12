import AppKit
import Combine
import SwiftUI

@MainActor
final class TaskbarController: NSObject {
    static var barHeight: CGFloat { TaskbarMetrics.barHeight }

    private let viewModel: TaskbarViewModel
    private var panel: NSPanel?
    private var startMenuPanel: NSPanel?
    private var modifierKeysPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(
        appMonitor: AppMonitor,
        pinnedStore: PinnedAppsStore,
        startMenuCatalog: StartMenuCatalog,
        modifierKeyRemapper: ModifierKeyRemapper
    ) {
        self.viewModel = TaskbarViewModel(
            appMonitor: appMonitor,
            pinnedStore: pinnedStore,
            startMenuCatalog: startMenuCatalog,
            modifierKeyRemapper: modifierKeyRemapper,
            batteryMonitor: BatteryMonitor(),
            spacesMonitor: SpacesMonitor(),
            trashMonitor: TrashMonitor()
        )
        super.init()
    }

    func show() {
        createStatusItem()
        createTaskbarPanel()
        layoutPanels()
        observeScreens()
        observeClicksOutside()
        viewModel.startTrayMonitors()

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
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "menubar.dock.rectangle",
                accessibilityDescription: "TaskListBar"
            )
            button.toolTip = "TaskListBar"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "打开开始菜单", action: #selector(statusOpenStartMenu), keyEquivalent: "")
        menu.addItem(withTitle: "修饰键设置", action: #selector(statusOpenModifierKeys), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示任务栏", action: #selector(statusShowTaskbar), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TaskListBar", action: #selector(statusQuit), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func statusOpenStartMenu() {
        viewModel.isStartMenuOpen = true
        viewModel.isModifierKeysOpen = false
        viewModel.startMenuCatalog.refresh()
    }

    @objc private func statusOpenModifierKeys() {
        viewModel.openModifierKeysSettings()
    }

    @objc private func statusShowTaskbar() {
        layoutPanels()
        panel?.orderFrontRegardless()
    }

    @objc private func statusQuit() {
        NSApp.terminate(nil)
    }

    private func createTaskbarPanel() {
        let glass = GlassPanelFactory.wrap(
            TaskbarRootView(viewModel: viewModel),
            material: .menu
        )

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // High enough to sit above Dock and third-party bars like uBar.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = glass
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func createStartMenuPanelIfNeeded() {
        if startMenuPanel != nil { return }

        let glass = GlassPanelFactory.wrap(
            StartMenuView(viewModel: viewModel),
            material: .popover
        )

        let panel = NSPanel(
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
            ModifierKeysSettingsView(remapper: viewModel.modifierKeyRemapper) { [weak self] in
                self?.viewModel.closeModifierKeysSettings()
            },
            material: .popover
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
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

        modifierKeysPanel = panel
    }

    private func layoutPanels() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame

        let barFrame = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: Self.barHeight
        )

        panel?.setFrame(barFrame, display: true)
        panel?.orderFrontRegardless()

        if let start = startMenuPanel {
            let menuWidth: CGFloat = 420
            let menuHeight: CGFloat = min(560, max(360, visible.height - 80))
            let menuFrame = NSRect(
                x: frame.minX + 8,
                y: frame.minY + Self.barHeight + 8,
                width: menuWidth,
                height: menuHeight
            )
            start.setFrame(menuFrame, display: true)
        }

        if let modifiers = modifierKeysPanel {
            let menuFrame = NSRect(
                x: frame.minX + 8,
                y: frame.minY + Self.barHeight + 8,
                width: 420,
                height: 420
            )
            modifiers.setFrame(menuFrame, display: true)
        }
    }

    private func syncStartMenuVisibility() {
        if viewModel.isStartMenuOpen {
            createStartMenuPanelIfNeeded()
            layoutPanels()
            startMenuPanel?.orderFrontRegardless()
            startMenuPanel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            startMenuPanel?.orderOut(nil)
        }
    }

    private func syncModifierKeysVisibility() {
        if viewModel.isModifierKeysOpen {
            createModifierKeysPanelIfNeeded()
            layoutPanels()
            modifierKeysPanel?.orderFrontRegardless()
            modifierKeysPanel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            modifierKeysPanel?.orderOut(nil)
        }
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.layoutPanels()
            }
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
    }
}
