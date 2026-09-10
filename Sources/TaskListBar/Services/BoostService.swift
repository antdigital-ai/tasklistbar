import Combine
import Foundation

/// 一键「加速」：强制关闭 AI 编码 agent 与开发 / 编译类进程，释放 CPU 与内存。
@MainActor
final class BoostService: ObservableObject {
    struct Snapshot: Equatable {
        var generation = 0
        var killed = 0
        var reclaimedBytes: Int64 = 0
        var timestamp: Date?
        var message = "尚未执行"
    }

    struct Pressure: Equatable {
        var isHigh = false
        var cpuShare = 0.0
        var memoryShare = 0.0
        var rssMB = 0
        var cpuPercent = 0
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isRunning = false
    @Published private(set) var pressure = Pressure()
    @Published private(set) var lastGroups: [ProcessGroup] = []
    @Published private(set) var lastDisks: [DiskItem] = []
    @Published private(set) var disksCached = false

    /// 一组可清理的进程，供选择面板展示。
    struct ProcessGroup: Identifiable, Equatable {
        let label: String
        let pids: [String]
        var id: String { label }
        var count: Int { pids.count }
    }

    /// 一块可回收的磁盘占用：过期 worktree，或 Node 依赖 / 包管理器缓存。
    struct DiskItem: Identifiable, Equatable {
        enum Kind: String {
            case staleWorktrees
            case recentWorktrees
            case nodeDependencies
        }

        struct Entry: Equatable {
            let url: URL
            let bytes: Int64
            let source: String
        }

        let kind: Kind
        let label: String
        let detail: String
        let entries: [Entry]
        let selectedByDefault: Bool

        var id: String { kind.rawValue }
        var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
        var count: Int { entries.count }
    }

    private struct Target {
        let label: String
        let patterns: [String]
        let fullCommandLine: Bool
    }

    nonisolated private static let targets: [Target] = [
        // Cursor：只回收 AI agent / 编译类子进程，保留主进程与 Renderer。
        // 切回窗口时 Cursor 会自动重启这些子进程，省去整应用重启的成本。
        Target(label: "Cursor Agent 子进程", patterns: [
            "Cursor Helper \\(Plugin\\): extension-host",
            "Cursor Helper: fileWatcher",
            "Cursor Helper: mcp-process",
            "Cursor Helper: conversation-search",
            "Cursor Helper: shared-process",
            "Cursor Helper: terminal pty-host",
        ], fullCommandLine: true),

        // ChatGPT：只回收 agent worker（cua_node / codex CLI），保留主应用、
        // Framework helper，以及 Resources 里的输入监控等常驻组件。
        Target(label: "ChatGPT Agent 子进程", patterns: [
            "ChatGPT\\.app/Contents/Resources/cua_node/",
            "ChatGPT\\.app/Contents/Resources/codex ",
            "ChatGPT\\.app/Contents/Resources/codex-code-mode-host",
        ], fullCommandLine: true),

        // AiWork：只回收 agent CLI 守护进程。不要动 Electron Helper
        // （网络 / GPU / Renderer / Plugin），否则应用会变成半死、再也打不开。
        Target(label: "AiWork Agent 子进程", patterns: [
            "dtcodercli-internal",
        ], fullCommandLine: true),

        Target(label: "VS Code", patterns: ["Visual Studio Code\\.app", "Code Helper"], fullCommandLine: true),
        Target(label: "Windsurf", patterns: ["Windsurf\\.app", "Windsurf Helper"], fullCommandLine: true),
        Target(label: "Zed", patterns: ["Zed\\.app"], fullCommandLine: true),

        // 独立 AI CLI Agent
        Target(label: "Claude Code", patterns: ["^claude$"], fullCommandLine: false),
        Target(label: "Codex", patterns: ["^codex$"], fullCommandLine: false),
        Target(label: "Gemini", patterns: ["^gemini$"], fullCommandLine: false),
        Target(label: "OpenCode", patterns: ["^opencode$"], fullCommandLine: false),
        Target(label: "Aider", patterns: ["^aider$"], fullCommandLine: false),

        // 运行时
        Target(label: "Node.js", patterns: ["^node$"], fullCommandLine: false),
        Target(label: "Bun", patterns: ["^bun$"], fullCommandLine: false),
        Target(label: "Deno", patterns: ["^deno$"], fullCommandLine: false),

        // 编译器 / 语言服务器
        Target(label: "TypeScript Go", patterns: ["^tsgo$"], fullCommandLine: false),
        Target(label: "Rust", patterns: ["^rustc$", "^rust-analyzer$", "^rustfmt$", "^cargo$"], fullCommandLine: false),
        Target(label: "Go", patterns: ["^go$", "^gopls$"], fullCommandLine: false),
        Target(label: "Swift", patterns: ["^swift-frontend$", "^sourcekit-lsp$"], fullCommandLine: false),
        Target(label: "C/C++", patterns: ["^clangd$"], fullCommandLine: false),
        Target(label: "Python", patterns: ["^pyright$", "^pylance$"], fullCommandLine: false),

        // 打包器
        Target(label: "esbuild", patterns: ["^esbuild$"], fullCommandLine: false),
    ]

    /// 只统计会拖慢机器的 AI agent，不含编辑器主进程 / Renderer。
    nonisolated private static let watchTokens: [String] = [
        "extension-host",
        "fileWatcher",
        "mcp-process",
        "conversation-search",
        "dtcodercli-internal",
        "cua_node",
        "codex-code-mode-host",
        "codex app-server",
    ]

    /// CPU 占整机 ≥ 18%，或内存占物理内存 ≥ 15%（且至少 800MB），视为偏高。
    nonisolated private static let highCPUShare = 0.18
    nonisolated private static let highMemoryShare = 0.15
    nonisolated private static let highMemoryFloorMB = 800

    private let queue = DispatchQueue(label: "keelbar.boost", qos: .utility)
    private var pressureTimer: DispatchSourceTimer?
    private var groupsCachedAt = Date.distantPast
    private var disksCachedAt = Date.distantPast

    private struct ProcessRow {
        let pid: String
        let cpu: Double
        let rssKB: Double
        let command: String
        let name: String
    }

    private struct SizeStamp {
        let mtime: TimeInterval
        let count: Int
        let bytes: Int64
    }

    private final class RuntimeCache: @unchecked Sendable {
        static let shared = RuntimeCache()
        private let lock = NSLock()
        private var table: (at: Date, rows: [ProcessRow])?
        private var sizes: [String: SizeStamp] = [:]

        func processTable(ttl: TimeInterval) -> [ProcessRow]? {
            lock.lock()
            defer { lock.unlock() }
            guard let table, Date().timeIntervalSince(table.at) < ttl else { return nil }
            return table.rows
        }

        func storeProcessTable(_ rows: [ProcessRow]) {
            lock.lock()
            table = (Date(), rows)
            lock.unlock()
        }

        func size(for path: String, mtime: TimeInterval, count: Int) -> Int64? {
            lock.lock()
            defer { lock.unlock() }
            guard let stamp = sizes[path], stamp.mtime == mtime, stamp.count == count else { return nil }
            return stamp.bytes
        }

        func storeSize(path: String, mtime: TimeInterval, count: Int, bytes: Int64) {
            lock.lock()
            sizes[path] = SizeStamp(mtime: mtime, count: count, bytes: bytes)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            table = nil
            sizes.removeAll()
            lock.unlock()
        }
    }

    private static let processTTL: TimeInterval = 12
    private static let diskTTL: TimeInterval = 90
    nonisolated private static let tableTTL: TimeInterval = 8

    nonisolated private static let compiledTargets: [(label: String, matchers: [(regex: NSRegularExpression, fullCommandLine: Bool)])] = {
        targets.map { target in
            let matchers = target.patterns.compactMap { pattern -> (NSRegularExpression, Bool)? in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
                return (regex, target.fullCommandLine)
            }
            return (target.label, matchers)
        }
    }()

    func start() {
        samplePressure()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(12))
        timer.setEventHandler { [weak self] in
            self?.samplePressure()
        }
        timer.resume()
        pressureTimer = timer
    }

    func stop() {
        pressureTimer?.cancel()
        pressureTimer = nil
    }

    /// 扫描当前可清理的进程，按目标分组。结果不含空组。
    func scan(force: Bool = false) async -> [ProcessGroup] {
        if !force, Date().timeIntervalSince(groupsCachedAt) < Self.processTTL, !lastGroups.isEmpty {
            return lastGroups
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let groups = Self.scanProcesses()
                Task { @MainActor in
                    self.lastGroups = groups
                    self.groupsCachedAt = Date()
                    continuation.resume(returning: groups)
                }
            }
        }
    }

    /// 扫描可回收的 worktree 与 Node 依赖。
    func scanDisk(force: Bool = false) async -> [DiskItem] {
        if !force, Date().timeIntervalSince(disksCachedAt) < Self.diskTTL, disksCached {
            return lastDisks
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let disks = Self.scanDiskSync()
                Task { @MainActor in
                    self.lastDisks = disks
                    self.disksCachedAt = Date()
                    self.disksCached = true
                    continuation.resume(returning: disks)
                }
            }
        }
    }

    /// 关闭选中进程，并删除选中的 worktree / Node 依赖。
    func boost(groups: [ProcessGroup], disks: [DiskItem] = []) {
        guard !isRunning else { return }
        isRunning = true
        let pids = groups.flatMap(\.pids)

        queue.async {
            if !pids.isEmpty {
                _ = Self.run("/bin/kill", arguments: ["-9"] + pids)
            }
            let reclaimed = Self.reclaimSync(disks)
            let killed = pids.count
            let message = Self.cleanupMessage(killed: killed, bytes: reclaimed, hadSelection: !pids.isEmpty || !disks.isEmpty)
            RuntimeCache.shared.reset()
            Task { @MainActor in
                var snap = self.snapshot
                snap.generation += 1
                snap.killed = killed
                snap.reclaimedBytes = reclaimed
                snap.timestamp = Date()
                snap.message = message
                self.snapshot = snap
                self.isRunning = false
                self.lastGroups = []
                self.lastDisks = []
                self.disksCached = false
                self.groupsCachedAt = .distantPast
                self.disksCachedAt = .distantPast
                AppLog.info("加速：\(message)", category: "boost")
                self.samplePressure()
            }
        }
    }

    nonisolated static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", value / 1_073_741_824)
        }
        if value >= 1_048_576 {
            return "\(Int((value / 1_048_576).rounded())) MB"
        }
        if value >= 1024 {
            return "\(Int((value / 1024).rounded())) KB"
        }
        return "\(Int(value)) B"
    }

    private func samplePressure() {
        queue.async { [weak self] in
            let next = Self.readPressure()
            Task { @MainActor in
                guard let self, next != self.pressure else { return }
                self.pressure = next
            }
        }
    }

    private nonisolated static func readPressure() -> Pressure {
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let tokens = watchTokens
        var cpu = 0.0
        var rssKB = 0.0

        for row in processTable() {
            guard tokens.contains(where: { row.command.contains($0) }) else { continue }
            cpu += row.cpu
            rssKB += row.rssKB
        }

        let cpuShare = cpu / (Double(cores) * 100)
        let memoryShare = physical > 0 ? (rssKB * 1024) / physical : 0
        let rssMB = Int((rssKB / 1024).rounded())
        let isHigh = cpuShare >= highCPUShare
            || (memoryShare >= highMemoryShare && rssMB >= highMemoryFloorMB)
        return Pressure(
            isHigh: isHigh,
            cpuShare: cpuShare,
            memoryShare: memoryShare,
            rssMB: rssMB,
            cpuPercent: Int((cpuShare * 100).rounded())
        )
    }

    private nonisolated static func scanProcesses() -> [ProcessGroup] {
        let rows = processTable()
        var used = Set<String>()
        var groups: [ProcessGroup] = []
        for target in compiledTargets {
            var pids: [String] = []
            for row in rows {
                guard !used.contains(row.pid) else { continue }
                let matched = target.matchers.contains { matcher in
                    let haystack = matcher.fullCommandLine ? row.command : row.name
                    let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
                    return matcher.regex.firstMatch(in: haystack, options: [], range: range) != nil
                }
                guard matched else { continue }
                used.insert(row.pid)
                pids.append(row.pid)
            }
            if !pids.isEmpty {
                groups.append(ProcessGroup(label: target.label, pids: pids.sorted()))
            }
        }
        return groups
    }

    private nonisolated static func processTable() -> [ProcessRow] {
        if let cached = RuntimeCache.shared.processTable(ttl: tableTTL) {
            return cached
        }
        let output = run("/bin/ps", arguments: ["-A", "-o", "pid=,pcpu=,rss=,command="]).output
        var rows: [ProcessRow] = []
        rows.reserveCapacity(256)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 4 else { continue }
            let command = String(parts[3])
            let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
            rows.append(
                ProcessRow(
                    pid: String(parts[0]),
                    cpu: Double(parts[1]) ?? 0,
                    rssKB: Double(parts[2]) ?? 0,
                    command: command,
                    name: URL(fileURLWithPath: first).lastPathComponent
                )
            )
        }
        RuntimeCache.shared.storeProcessTable(rows)
        return rows
    }

    private nonisolated static func run(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return (1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Disk

    /// 最近 36 小时改过的 worktree 默认不勾选，避免误删正在用的。
    nonisolated private static let recentWorktreeInterval: TimeInterval = 36 * 60 * 60
    nonisolated private static let minimumCacheBytes: Int64 = 1_048_576

    nonisolated private static let worktreeRootNames = [
        ".cursor/worktrees",
        ".codex/worktrees",
        ".claude/worktrees"
    ]

    nonisolated private static let nodeCacheRelatives = [
        ".npm",
        ".bun/install/cache",
        ".pnpm-store",
        ".yarn/berry/cache",
        ".local/share/pnpm/store",
        "Library/pnpm/store",
        "Library/Caches/pnpm",
        "Library/Caches/Yarn",
        "Library/Caches/node-gyp"
    ]

    private nonisolated static func scanDiskSync() -> [DiskItem] {
        let roots = worktreeRoots()
        let worktrees = discoverWorktrees(in: roots)
        let stale = worktrees.filter { !$0.isRecent }
        let recent = worktrees.filter(\.isRecent)
        var items: [DiskItem] = []

        if let item = makeWorktreeItem(
            kind: .staleWorktrees,
            label: "过期 Worktree",
            records: stale,
            selectedByDefault: true
        ) {
            items.append(item)
        }
        if let item = makeWorktreeItem(
            kind: .recentWorktrees,
            label: "最近 Worktree",
            records: recent,
            selectedByDefault: false
        ) {
            items.append(item)
        }
        if let item = makeNodeDependencyItem(worktrees: worktrees) {
            items.append(item)
        }
        return items
    }

    private nonisolated static func makeWorktreeItem(
        kind: DiskItem.Kind,
        label: String,
        records: [WorktreeRecord],
        selectedByDefault: Bool
    ) -> DiskItem? {
        guard !records.isEmpty else { return nil }
        let entries = records.map {
            DiskItem.Entry(url: $0.url, bytes: $0.bytes, source: $0.name)
        }
        let detail: String
        if records.count == 1 {
            detail = records[0].name
        } else {
            detail = "\(records.count) 个"
        }
        return DiskItem(
            kind: kind,
            label: label,
            detail: detail,
            entries: entries,
            selectedByDefault: selectedByDefault
        )
    }

    private nonisolated static func makeNodeDependencyItem(worktrees: [WorktreeRecord]) -> DiskItem? {
        var entries: [DiskItem.Entry] = []
        var sources: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        for relative in nodeCacheRelatives {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            guard isExistingDirectory(url), !isSymbolicLink(url) else { continue }
            let bytes = directoryBytes(url)
            guard bytes >= minimumCacheBytes else { continue }
            entries.append(DiskItem.Entry(url: url, bytes: bytes, source: cacheLabel(for: relative)))
            let name = cacheLabel(for: relative)
            if !sources.contains(name) { sources.append(name) }
        }

        for worktree in worktrees {
            for url in realNodeModuleDirectories(in: worktree.url) {
                let bytes = directoryBytes(url)
                guard bytes > 0 else { continue }
                entries.append(DiskItem.Entry(url: url, bytes: bytes, source: "node_modules"))
            }
        }
        if entries.contains(where: { $0.source == "node_modules" }), !sources.contains("node_modules") {
            sources.append("node_modules")
        }

        guard !entries.isEmpty else { return nil }
        return DiskItem(
            kind: .nodeDependencies,
            label: "Node 依赖",
            detail: sources.joined(separator: " · "),
            entries: entries,
            selectedByDefault: true
        )
    }

    private struct WorktreeRecord {
        let url: URL
        let name: String
        let bytes: Int64
        let isRecent: Bool
    }

    private nonisolated static func worktreeRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return worktreeRootNames.compactMap { relative in
            let url = home.appendingPathComponent(relative, isDirectory: true)
            return isExistingDirectory(url) ? url.standardizedFileURL : nil
        }
    }

    private nonisolated static func discoverWorktrees(in roots: [URL]) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        let now = Date()
        for root in roots {
            guard let repos = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for repo in repos {
                guard isExistingDirectory(repo), !isSymbolicLink(repo) else { continue }
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: repo,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children {
                    guard isExistingDirectory(child), !isSymbolicLink(child) else { continue }
                    let relative = child.path
                        .replacingOccurrences(of: root.path.hasSuffix("/") ? root.path : root.path + "/", with: "")
                    let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    records.append(
                        WorktreeRecord(
                            url: child.standardizedFileURL,
                            name: relative,
                            bytes: directoryBytes(child),
                            isRecent: now.timeIntervalSince(modified) < recentWorktreeInterval
                        )
                    )
                }
            }
        }
        return records.sorted { $0.bytes > $1.bytes }
    }

    private nonisolated static func realNodeModuleDirectories(in worktree: URL) -> [URL] {
        var found: [URL] = []
        let direct = worktree.appendingPathComponent("node_modules", isDirectory: true)
        if isExistingDirectory(direct), !isSymbolicLink(direct) {
            found.append(direct.standardizedFileURL)
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: worktree,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return found }
        for child in children {
            guard isExistingDirectory(child), !isSymbolicLink(child) else { continue }
            let nested = child.appendingPathComponent("node_modules", isDirectory: true)
            if isExistingDirectory(nested), !isSymbolicLink(nested) {
                found.append(nested.standardizedFileURL)
            }
        }
        return found
    }

    private nonisolated static func reclaimSync(_ items: [DiskItem]) -> Int64 {
        let worktreesFirst = items.filter { $0.kind != .nodeDependencies }
        let nodeItems = items.filter { $0.kind == .nodeDependencies }
        var removed: Int64 = 0
        var deletedWorktrees: [URL] = []

        for item in worktreesFirst {
            for entry in item.entries {
                guard isAllowed(entry.url) else { continue }
                let bytes = entry.bytes > 0 ? entry.bytes : directoryBytes(entry.url)
                if removeReclaimable(entry.url) {
                    removed += bytes
                    deletedWorktrees.append(entry.url)
                    pruneEmptyParents(of: entry.url)
                }
            }
        }

        for item in nodeItems {
            for entry in item.entries {
                guard isAllowed(entry.url) else { continue }
                if deletedWorktrees.contains(where: { entry.url.path.hasPrefix($0.path + "/") }) {
                    continue
                }
                guard isExistingDirectory(entry.url), !isSymbolicLink(entry.url) else { continue }
                let bytes = entry.bytes > 0 ? entry.bytes : directoryBytes(entry.url)
                if removeReclaimable(entry.url) {
                    removed += bytes
                }
            }
        }
        return removed
    }

    @discardableResult
    private nonisolated static func removeReclaimable(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard isAllowed(standardized) else { return false }
        unlinkGitWorktree(standardized)
        guard FileManager.default.fileExists(atPath: standardized.path) else { return true }
        do {
            try FileManager.default.removeItem(at: standardized)
            return true
        } catch {
            AppLog.error("删除失败 \(standardized.path): \(error.localizedDescription)", category: "boost")
            return false
        }
    }

    private nonisolated static func unlinkGitWorktree(_ url: URL) {
        let git = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue,
              let text = try? String(contentsOf: git, encoding: .utf8)
        else { return }

        guard let line = text.split(whereSeparator: \.isNewline).first(where: {
            $0.lowercased().hasPrefix("gitdir:")
        }) else { return }
        let raw = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        var gitdir = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        if gitdir.lastPathComponent.isEmpty { gitdir.deleteLastPathComponent() }
        gitdir.deleteLastPathComponent()
        if gitdir.lastPathComponent == "worktrees" {
            gitdir.deleteLastPathComponent()
        }
        if gitdir.lastPathComponent == ".git" {
            gitdir.deleteLastPathComponent()
        }
        let repo = gitdir
        guard FileManager.default.fileExists(atPath: repo.path) else { return }
        _ = run("/usr/bin/git", arguments: ["-C", repo.path, "worktree", "remove", "--force", url.path])
        _ = run("/usr/bin/git", arguments: ["-C", repo.path, "worktree", "prune"])
    }

    private nonisolated static func pruneEmptyParents(of url: URL) {
        let roots = worktreeRoots()
        var parent = url.standardizedFileURL.deletingLastPathComponent()
        while roots.contains(where: { root in
            let path = parent.path
            return path.hasPrefix(root.path + "/") && path != root.path
        }) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? ["."]
            let leftover = contents.filter { $0 != ".DS_Store" }
            guard leftover.isEmpty else { return }
            try? FileManager.default.removeItem(at: parent)
            parent.deleteLastPathComponent()
        }
    }

    private nonisolated static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.count > 16, !path.contains("\0") else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let worktreePrefixes = worktreeRootNames.map { home + "/" + $0 + "/" }
        if worktreePrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        return nodeCacheRelatives.contains { relative in
            let prefix = home + "/" + relative
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private nonisolated static func directoryBytes(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let cached = RuntimeCache.shared.size(for: url.path, mtime: mtime, count: 0) {
            return cached
        }
        let output = run("/usr/bin/du", arguments: ["-sk", url.path]).output
        let value = output.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) } ?? 0
        let bytes = value * 1024
        RuntimeCache.shared.storeSize(path: url.path, mtime: mtime, count: 0, bytes: bytes)
        return bytes
    }

    private nonisolated static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private nonisolated static func cacheLabel(for relative: String) -> String {
        if relative.contains(".npm") { return "npm" }
        if relative.contains(".bun") { return "bun" }
        if relative.lowercased().contains("pnpm") { return "pnpm" }
        if relative.lowercased().contains("yarn") { return "yarn" }
        if relative.contains("node-gyp") { return "node-gyp" }
        return relative
    }

    private nonisolated static func cleanupMessage(killed: Int, bytes: Int64, hadSelection: Bool) -> String {
        var parts: [String] = []
        if killed > 0 { parts.append("已关闭 \(killed) 个进程") }
        if bytes > 0 { parts.append("回收 \(formatBytes(bytes))") }
        if parts.isEmpty {
            return hadSelection ? "没有可回收的项目" : "未选择项目"
        }
        return parts.joined(separator: "，")
    }
}
