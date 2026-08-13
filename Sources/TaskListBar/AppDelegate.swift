import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var taskbarController: TaskbarController?
    private var appSettings: AppSettings?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.bootstrap()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            AppLog.info("开始初始化任务栏")
            let appMonitor = AppMonitor()
            let pinnedStore = PinnedAppsStore()
            let startMenuCatalog = StartMenuCatalog()
            let modifierKeyRemapper = ModifierKeyRemapper()
            let appSettings = AppSettings()
            appSettings.applyOnLaunch()
            self.appSettings = appSettings

            let controller = TaskbarController(
                appMonitor: appMonitor,
                pinnedStore: pinnedStore,
                startMenuCatalog: startMenuCatalog,
                modifierKeyRemapper: modifierKeyRemapper,
                appSettings: appSettings
            )
            self.taskbarController = controller
            controller.show()

            appMonitor.start()
            startMenuCatalog.refresh(force: false)
            AppLog.info("任务栏已显示")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: AppSettingKey.hideSystemDock) {
            DockHider.restore()
        }
        AppLog.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
