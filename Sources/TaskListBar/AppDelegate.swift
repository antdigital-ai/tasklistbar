import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var taskbarController: TaskbarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            let appMonitor = AppMonitor()
            let pinnedStore = PinnedAppsStore()
            let startMenuCatalog = StartMenuCatalog()
            let modifierKeyRemapper = ModifierKeyRemapper()

            let controller = TaskbarController(
                appMonitor: appMonitor,
                pinnedStore: pinnedStore,
                startMenuCatalog: startMenuCatalog,
                modifierKeyRemapper: modifierKeyRemapper
            )
            self.taskbarController = controller
            controller.show()

            appMonitor.start()
            startMenuCatalog.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
