import Foundation
import ServiceManagement

enum LoginItemService {
    static let agentLabel = AppSupport.bundleID
    private static let legacyAgentLabel = "com.tasklistbar.app"

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(legacyAgentLabel).plist")
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
            || FileManager.default.fileExists(atPath: legacyURL.path)
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var runningAsAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(agentLabel).plist")
    }

    private static func enable() throws {
        removeLegacyLaunchAgent()
        if runningAsAppBundle {
            do {
                try SMAppService.mainApp.register()
                return
            } catch {
                // Fall back to a LaunchAgent so unsigned local builds still work.
                try installLaunchAgent()
                return
            }
        }
        try installLaunchAgent()
    }

    private static func disable() throws {
        if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try? SMAppService.mainApp.unregister()
        }
        removeLaunchAgent()
    }

    private static func installLaunchAgent() throws {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let arguments: [String]
        if runningAsAppBundle {
            arguments = ["/usr/bin/open", "-a", Bundle.main.bundleURL.path]
        } else {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            arguments = [executable]
        }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", "\(domain)/\(agentLabel)"])
        let status = runLaunchctl(["bootstrap", domain, launchAgentURL.path])
        if status != 0 {
            _ = runLaunchctl(["enable", "\(domain)/\(agentLabel)"])
        }
    }

    private static func removeLaunchAgent() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", "\(domain)/\(agentLabel)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
        removeLegacyLaunchAgent()
    }

    private static func removeLegacyLaunchAgent() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", "\(domain)/\(legacyAgentLabel)"])
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(legacyAgentLabel).plist")
        try? FileManager.default.removeItem(at: legacyURL)
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
