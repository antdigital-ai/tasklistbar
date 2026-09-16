import AppKit
import Combine
import Foundation

/// 一键「加速」：强制关闭 AI 编码 agent 与开发 / 编译类进程，释放 CPU 与内存。
@MainActor
final class BoostService: ObservableObject {
    enum CleanupKind: Equatable {
        case idle
        case boost
        case worktree
    }

    struct Snapshot: Equatable {
        var generation = 0
        var kind: CleanupKind = .idle
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
    @Published private(set) var lastWorktrees: [WorktreeItem] = []
    @Published private(set) var lastRecentRepos: [RecentRepo] = []
    @Published private(set) var disksCached = false
    @Published private(set) var worktreesCached = false
    @Published private(set) var recentReposCached = false

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

    /// 一棵可删除的关联 Worktree（不含主工作区）。
    struct WorktreeItem: Identifiable, Equatable {
        let url: URL
        let name: String
        let detail: String
        let bytes: Int64
        let isRecent: Bool

        var id: String { url.path }
        var selectedByDefault: Bool { !isRecent }
    }

    /// Cursor / ChatGPT / Claude Code 最近用过的 Git 主仓库。
    struct RecentRepo: Identifiable, Equatable {
        let url: URL
        let name: String
        let sources: [String]
        let lastActive: Date
        let worktreeCount: Int

        var id: String { url.path }

        var detail: String {
            var parts = sources
            parts.append(Self.relativeTime(lastActive))
            if worktreeCount > 0 {
                parts.append("\(worktreeCount) worktrees")
            }
            return parts.joined(separator: " · ")
        }

        private static func relativeTime(_ date: Date) -> String {
            let seconds = Date().timeIntervalSince(date)
            if seconds < 60 { return "Just now" }
            if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
            if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
            if seconds < 172_800 { return "Yesterday" }
            if seconds < 864_000 { return "\(Int(seconds / 86_400))d ago" }
            return "\(Int(seconds / 604_800))w ago"
        }
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
    private var worktreesCachedAt = Date.distantPast
    private var worktreesCachedRepo: String?
    private var recentReposCachedAt = Date.distantPast

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
        prefetchRecentRepos()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(12))
        timer.setEventHandler { [weak self] in
            self?.samplePressure()
        }
        timer.resume()
        pressureTimer = timer
    }

    func prefetchRecentRepos() {
        Task { await scanRecentRepos(force: false) }
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

    /// 扫描可回收的 Node 包管理器缓存。
    func scanDisk(force: Bool = false) async -> [DiskItem] {
        if !force, Date().timeIntervalSince(disksCachedAt) < Self.diskTTL, disksCached {
            return lastDisks
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let disks = Self.scanNodeCaches()
                Task { @MainActor in
                    self.lastDisks = disks
                    self.disksCachedAt = Date()
                    self.disksCached = true
                    continuation.resume(returning: disks)
                }
            }
        }
    }

    /// 扫描可删除的关联 Worktree。`repoPath` 为空时扫 Cursor / Codex / Claude 目录。
    func scanWorktrees(repoPath: String?, force: Bool = false) async -> [WorktreeItem] {
        if !force,
           Date().timeIntervalSince(worktreesCachedAt) < Self.diskTTL,
           worktreesCached,
           worktreesCachedRepo == repoPath {
            return lastWorktrees
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let items = Self.scanWorktreesSync(repoPath: repoPath)
                Task { @MainActor in
                    self.lastWorktrees = items
                    self.worktreesCachedAt = Date()
                    self.worktreesCachedRepo = repoPath
                    self.worktreesCached = true
                    continuation.resume(returning: items)
                }
            }
        }
    }

    func scanRecentRepos(force: Bool = false) async -> [RecentRepo] {
        if !force, Date().timeIntervalSince(recentReposCachedAt) < 30, recentReposCached {
            return lastRecentRepos
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let items = Self.scanRecentReposSync()
                Task { @MainActor in
                    self.lastRecentRepos = items
                    self.recentReposCachedAt = Date()
                    self.recentReposCached = true
                    AppLog.info("最近 Git 项目 \(items.count) 个", category: "boost")
                    continuation.resume(returning: items)
                }
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func cleanWorktrees(_ items: [WorktreeItem]) {
        guard !isRunning else { return }
        isRunning = true
        queue.async {
            let reclaimed = Self.reclaimWorktreesSync(items.map(\.url))
            let message = Self.cleanupMessage(killed: 0, bytes: reclaimed, hadSelection: !items.isEmpty)
            RuntimeCache.shared.reset()
            Task { @MainActor in
                var snap = self.snapshot
                snap.generation += 1
                snap.kind = .worktree
                snap.killed = 0
                snap.reclaimedBytes = reclaimed
                snap.timestamp = Date()
                snap.message = message
                self.snapshot = snap
                self.isRunning = false
                self.lastWorktrees = []
                self.worktreesCached = false
                self.worktreesCachedAt = .distantPast
                AppLog.info("Worktree 清理：\(message)", category: "boost")
            }
        }
    }

    /// 关闭选中进程，并删除选中的 Node 缓存。
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
                snap.kind = .boost
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

    nonisolated static func resolvedGitRepo(at url: URL) -> URL? {
        resolvedMainRepo(at: url)
    }

    private nonisolated static func resolvedMainRepo(at url: URL) -> URL? {
        let top = run("/usr/bin/git", arguments: ["-C", url.path, "rev-parse", "--show-toplevel"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty, FileManager.default.fileExists(atPath: top) else { return nil }
        let common = run("/usr/bin/git", arguments: ["-C", url.path, "rev-parse", "--git-common-dir"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else {
            return URL(fileURLWithPath: top, isDirectory: true).standardizedFileURL
        }
        var gitdir = URL(fileURLWithPath: common, relativeTo: url).standardizedFileURL
        if gitdir.lastPathComponent.isEmpty { gitdir.deleteLastPathComponent() }
        if gitdir.lastPathComponent != ".git" {
            gitdir.deleteLastPathComponent()
            if gitdir.lastPathComponent == "worktrees" {
                gitdir.deleteLastPathComponent()
            }
        }
        if gitdir.lastPathComponent == ".git" {
            gitdir.deleteLastPathComponent()
        }
        return FileManager.default.fileExists(atPath: gitdir.path) ? gitdir : URL(fileURLWithPath: top, isDirectory: true).standardizedFileURL
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

    private nonisolated static func scanNodeCaches() -> [DiskItem] {
        guard let item = makeNodeDependencyItem() else { return [] }
        return [item]
    }

    private struct RecentHit {
        let url: URL
        let source: String
        let at: Date
    }

    private nonisolated static func scanRecentReposSync() -> [RecentRepo] {
        var hits: [RecentHit] = []
        hits.append(contentsOf: cursorRecentHits())
        hits.append(contentsOf: claudeRecentHits())
        hits.append(contentsOf: codexRecentHits())

        var merged: [String: (url: URL, sources: Set<String>, at: Date)] = [:]
        for hit in hits {
            guard let repo = resolvedMainRepo(at: hit.url) else { continue }
            let key = repo.path
            if var current = merged[key] {
                current.sources.insert(hit.source)
                current.at = max(current.at, hit.at)
                merged[key] = current
            } else {
                merged[key] = (repo, [hit.source], hit.at)
            }
        }

        return merged.values
            .map { item in
                RecentRepo(
                    url: item.url,
                    name: item.url.lastPathComponent,
                    sources: ["Cursor", "ChatGPT", "Claude"].filter { item.sources.contains($0) },
                    lastActive: item.at,
                    worktreeCount: linkedWorktreeCount(repo: item.url)
                )
            }
            .sorted { $0.lastActive > $1.lastActive }
    }

    private nonisolated static func cursorRecentHits() -> [RecentHit] {
        var hits: [RecentHit] = []
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User", isDirectory: true)

        let db = support.appendingPathComponent("globalStorage/state.vscdb")
        if FileManager.default.fileExists(atPath: db.path) {
            let json = run("/usr/bin/sqlite3", arguments: [
                db.path,
                "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList';"
            ]).output
            if let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = object["entries"] as? [[String: Any]] {
                let now = Date()
                for (index, entry) in entries.enumerated() {
                    guard let raw = entry["folderUri"] as? String,
                          let path = filePath(fromURI: raw),
                          FileManager.default.fileExists(atPath: path)
                    else { continue }
                    let at = now.addingTimeInterval(TimeInterval(-index * 3600))
                    hits.append(RecentHit(url: URL(fileURLWithPath: path, isDirectory: true), source: "Cursor", at: at))
                }
            }
        }

        let storage = support.appendingPathComponent("workspaceStorage", isDirectory: true)
        if let folders = try? FileManager.default.contentsOfDirectory(
            at: storage,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for folder in folders {
                let meta = folder.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: meta),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = object["folder"] as? String,
                      let path = filePath(fromURI: raw),
                      FileManager.default.fileExists(atPath: path)
                else { continue }
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                hits.append(RecentHit(url: URL(fileURLWithPath: path, isDirectory: true), source: "Cursor", at: modified))
            }
        }
        return hits
    }

    private nonisolated static func filePath(fromURI raw: String) -> String? {
        if let url = URL(string: raw), url.isFileURL {
            return url.path
        }
        if raw.hasPrefix("file://") {
            return String(raw.dropFirst("file://".count))
        }
        return raw
    }

    private nonisolated static func claudeRecentHits() -> [RecentHit] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/history.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var latest: [String: Date] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["project"] as? String
            else { continue }
            let stamp = (object["timestamp"] as? Double).map { value -> Date in
                Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
            } ?? .distantPast
            latest[path] = max(latest[path] ?? .distantPast, stamp)
        }
        return latest.compactMap { path, date in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return RecentHit(url: URL(fileURLWithPath: path, isDirectory: true), source: "Claude", at: date)
        }
    }

    private nonisolated static func codexRecentHits() -> [RecentHit] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        let all = collectJSONL(under: root)
        var latest: [String: Date] = [:]
        for file in all {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = handle.readData(ofLength: 800)
            try? handle.close()
            guard let line = String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first,
                  let payload = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { continue }
            let cwd = ((object["payload"] as? [String: Any])?["cwd"] as? String) ?? (object["cwd"] as? String)
            guard let cwd, FileManager.default.fileExists(atPath: cwd) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            latest[cwd] = max(latest[cwd] ?? .distantPast, modified)
        }
        return latest.map { path, date in
            RecentHit(url: URL(fileURLWithPath: path, isDirectory: true), source: "ChatGPT", at: date)
        }
    }

    private nonisolated static func collectJSONL(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if file.pathExtension == "jsonl" {
                files.append(file)
            }
            if files.count > 80 { break }
        }
        return files
    }

    private nonisolated static func scanWorktreesSync(repoPath: String?) -> [WorktreeItem] {
        var records: [(record: WorktreeRecord, detail: String)] = []
        if let repoPath, !repoPath.isEmpty {
            let repo = URL(fileURLWithPath: repoPath, isDirectory: true).standardizedFileURL
            for record in discoverGitWorktrees(repo: repo) {
                records.append((record, repo.lastPathComponent))
            }
        } else {
            for root in worktreeRoots() {
                let source = worktreeSourceLabel(root)
                for record in discoverWorktrees(in: [root]) {
                    records.append((record, source))
                }
            }
        }
        var seen = Set<String>()
        return records.compactMap { pair in
            guard seen.insert(pair.record.url.path).inserted else { return nil }
            return WorktreeItem(
                url: pair.record.url,
                name: pair.record.name,
                detail: pair.record.isRecent ? "\(pair.detail) · 最近使用" : pair.detail,
                bytes: pair.record.bytes,
                isRecent: pair.record.isRecent
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private nonisolated static func makeNodeDependencyItem() -> DiskItem? {
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

    private nonisolated static func worktreeSourceLabel(_ root: URL) -> String {
        let path = root.path
        if path.contains(".cursor/") { return "Cursor" }
        if path.contains(".codex/") { return "Codex" }
        if path.contains(".claude/") { return "Claude" }
        return root.lastPathComponent
    }

    private nonisolated static func linkedWorktreeCount(repo: URL) -> Int {
        let output = run("/usr/bin/git", arguments: ["-C", repo.path, "worktree", "list", "--porcelain"]).output
        var count = 0
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("worktree ") else { continue }
            let path = String(line.dropFirst("worktree ".count))
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if isLinkedWorktree(url) { count += 1 }
        }
        return count
    }

    private nonisolated static func discoverGitWorktrees(repo: URL) -> [WorktreeRecord] {
        let output = run("/usr/bin/git", arguments: ["-C", repo.path, "worktree", "list", "--porcelain"]).output
        var paths: [URL] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("worktree ") else { continue }
            let path = String(line.dropFirst("worktree ".count))
            paths.append(URL(fileURLWithPath: path).standardizedFileURL)
        }
        let now = Date()
        return paths.compactMap { url in
            guard isExistingDirectory(url), isLinkedWorktree(url) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return WorktreeRecord(
                url: url,
                name: url.lastPathComponent,
                bytes: directoryBytes(url),
                isRecent: now.timeIntervalSince(modified) < recentWorktreeInterval
            )
        }
    }

    private nonisolated static func isLinkedWorktree(_ url: URL) -> Bool {
        let git = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
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

    private nonisolated static func reclaimWorktreesSync(_ urls: [URL]) -> Int64 {
        var removed: Int64 = 0
        for url in urls {
            guard isAllowed(url, extras: urls) else { continue }
            let bytes = directoryBytes(url)
            if removeReclaimable(url, extras: urls) {
                removed += bytes
                pruneEmptyParents(of: url)
            }
        }
        return removed
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
                if removeReclaimable(entry.url, extras: item.entries.map(\.url)) {
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
                if removeReclaimable(entry.url, extras: []) {
                    removed += bytes
                }
            }
        }
        return removed
    }

    @discardableResult
    private nonisolated static func removeReclaimable(_ url: URL, extras: [URL]) -> Bool {
        let standardized = url.standardizedFileURL
        guard isAllowed(standardized, extras: extras) else { return false }
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

    private nonisolated static func isAllowed(_ url: URL, extras: [URL] = []) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.count > 16, !path.contains("\0") else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return false }
        let worktreePrefixes = worktreeRootNames.map { home + "/" + $0 + "/" }
        if worktreePrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        if nodeCacheRelatives.contains(where: { relative in
            let prefix = home + "/" + relative
            return path == prefix || path.hasPrefix(prefix + "/")
        }) {
            return true
        }
        return extras.contains { $0.standardizedFileURL.path == path } && isLinkedWorktree(url)
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
