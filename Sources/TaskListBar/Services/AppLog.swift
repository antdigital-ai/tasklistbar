import AppKit
import Foundation
import os

enum AppLog {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private static let lock = NSLock()
    private static let logger = Logger(subsystem: AppSupport.bundleID, category: "app")
    private static var handle: FileHandle?
    private static var dayStamp = ""
    private static let keepDays = 7

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var directory: URL {
        AppSupport.root.appendingPathComponent("logs", isDirectory: true)
    }

    static var todayURL: URL {
        directory.appendingPathComponent("keelbar-\(dayFormatter.string(from: Date())).log")
    }

    static func bootstrap() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneLocked()
        openFileLocked()
        installCrashHandlers()
        writeLocked(.info, "app", "启动 \(appVersion)  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    static func shutdown() {
        info("退出")
        lock.lock()
        handle?.synchronizeFile()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }

    static func debug(_ message: String, category: String = "app") {
        write(.debug, category, message)
    }

    static func info(_ message: String, category: String = "app") {
        write(.info, category, message)
    }

    static func warn(_ message: String, category: String = "app") {
        write(.warn, category, message)
    }

    static func error(_ message: String, category: String = "app") {
        write(.error, category, message)
    }

    static func openInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    static func copyTodayToPasteboard() {
        let text = (try? String(contentsOf: todayURL, encoding: .utf8)) ?? "（今天还没有日志）"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func write(_ level: Level, _ category: String, _ message: String) {
        switch level {
        case .debug: logger.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .info: logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warn: logger.warning("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: logger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        lock.lock()
        writeLocked(level, category, message)
        lock.unlock()
    }

    private static func writeLocked(_ level: Level, _ category: String, _ message: String) {
        openFileLocked()
        let line = "\(timeFormatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle?.write(data)
        if level == .error || level == .warn {
            handle?.synchronizeFile()
        }
    }

    private static func openFileLocked() {
        let today = dayFormatter.string(from: Date())
        if today == dayStamp, handle != nil { return }
        try? handle?.close()
        handle = nil
        dayStamp = today
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("keelbar-\(today).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    private static func pruneLocked() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) ?? Date()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static var appVersion: String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let reason = exception.reason ?? ""
            AppLog.error("未捕获异常 \(exception.name.rawValue): \(reason)", category: "crash")
            let stack = exception.callStackSymbols.prefix(16).joined(separator: " | ")
            AppLog.error(stack, category: "crash")
        }
    }
}
