import Foundation

/// Hides the system Dock by turning on autohide and stretching the reveal delay
/// so the edge never pops our taskbar. Original prefs are snapshotted and restored.
enum DockHider {
    private static let suiteName = "com.apple.dock"
    private static let snapshotKey = "dockSnapshot"
    private static let autohideKey = "autohide"
    private static let delayKey = "autohide-delay"
    private static let timeKey = "autohide-time-modifier"

    private struct Snapshot: Codable {
        var hadAutohide: Bool
        var autohide: Bool
        var hadDelay: Bool
        var delay: Double
        var hadTimeModifier: Bool
        var timeModifier: Double
    }

    static func hide() {
        guard let dock = UserDefaults(suiteName: suiteName) else { return }
        saveSnapshotIfNeeded(dock)
        dock.set(true, forKey: autohideKey)
        dock.set(1000.0, forKey: delayKey)
        dock.set(0.0, forKey: timeKey)
        dock.synchronize()
        restartDock()
    }

    static func restore() {
        guard let dock = UserDefaults(suiteName: suiteName) else { return }
        if let snapshot = loadSnapshot() {
            apply(snapshot.hadAutohide, snapshot.autohide, key: autohideKey, dock: dock)
            apply(snapshot.hadDelay, snapshot.delay, key: delayKey, dock: dock)
            apply(snapshot.hadTimeModifier, snapshot.timeModifier, key: timeKey, dock: dock)
        } else {
            dock.removeObject(forKey: delayKey)
            dock.removeObject(forKey: timeKey)
            dock.set(false, forKey: autohideKey)
        }
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        dock.synchronize()
        restartDock()
    }

    private static func saveSnapshotIfNeeded(_ dock: UserDefaults) {
        guard UserDefaults.standard.data(forKey: snapshotKey) == nil else { return }
        let snapshot = Snapshot(
            hadAutohide: dock.object(forKey: autohideKey) != nil,
            autohide: dock.bool(forKey: autohideKey),
            hadDelay: dock.object(forKey: delayKey) != nil,
            delay: dock.double(forKey: delayKey),
            hadTimeModifier: dock.object(forKey: timeKey) != nil,
            timeModifier: dock.double(forKey: timeKey)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func apply(_ hadValue: Bool, _ value: Bool, key: String, dock: UserDefaults) {
        if hadValue {
            dock.set(value, forKey: key)
        } else {
            dock.removeObject(forKey: key)
        }
    }

    private static func apply(_ hadValue: Bool, _ value: Double, key: String, dock: UserDefaults) {
        if hadValue {
            dock.set(value, forKey: key)
        } else {
            dock.removeObject(forKey: key)
        }
    }

    private static func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
