import Foundation

enum AppSupport {
    static let folderName = "KeelBar"
    static let bundleID = "com.keelbar.app"

    static var root: URL {
        migrateIfNeeded()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func migrateIfNeeded() {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent("TaskListBar", isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.moveItem(at: legacy, to: current)
    }
}
