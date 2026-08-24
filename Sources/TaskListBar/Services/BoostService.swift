import Combine
import Foundation

/// 一键「加速」：强制关闭 AI 编码 agent 与开发 / 编译类进程，释放 CPU 与内存。
@MainActor
final class BoostService: ObservableObject {
    struct Snapshot: Equatable {
        var generation = 0
        var killed = 0
        var timestamp: Date?
        var message = "尚未执行"
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isRunning = false

    /// 一组可清理的进程，供选择面板展示。
    struct ProcessGroup: Identifiable, Equatable {
        let label: String
        let pids: [String]
        var id: String { label }
        var count: Int { pids.count }
    }

    private struct Target {
        let label: String
        let patterns: [String]
        let fullCommandLine: Bool
    }

    private static let targets: [Target] = [
        // AI 编码编辑器（Electron：主进程 + 重命名后的 Helper / extension-host / fileWatcher）
        Target(label: "Cursor", patterns: ["Cursor\\.app", "Cursor Helper"], fullCommandLine: true),
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

    private let queue = DispatchQueue(label: "keelbar.boost", qos: .userInitiated)

    /// 扫描当前可清理的进程，按目标分组。结果不含空组。
    func scan() async -> [ProcessGroup] {
        let targets = Self.targets
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.scanSync(targets: targets))
            }
        }
    }

    /// 只关闭选中分组的进程。
    func boost(groups: [ProcessGroup]) {
        guard !isRunning else { return }
        isRunning = true
        let pids = groups.flatMap(\.pids)

        queue.async {
            if !pids.isEmpty {
                _ = Self.run("/bin/kill", arguments: ["-9"] + pids)
            }
            let killed = pids.count
            let message = killed > 0 ? "已清理 \(killed) 个进程" : "未选择进程"
            Task { @MainActor in
                var snap = self.snapshot
                snap.generation += 1
                snap.killed = killed
                snap.timestamp = Date()
                snap.message = message
                self.snapshot = snap
                self.isRunning = false
                AppLog.info("加速：\(message)", category: "boost")
            }
        }
    }

    private nonisolated static func scanSync(targets: [Target]) -> [ProcessGroup] {
        var used = Set<String>()
        var groups: [ProcessGroup] = []
        for target in targets {
            var pids: [String] = []
            for pattern in target.patterns {
                for pid in matchingPIDs(pattern: pattern, fullCommandLine: target.fullCommandLine) {
                    if used.insert(pid).inserted {
                        pids.append(pid)
                    }
                }
            }
            if !pids.isEmpty {
                groups.append(ProcessGroup(label: target.label, pids: pids.sorted()))
            }
        }
        return groups
    }

    private nonisolated static func matchingPIDs(pattern: String, fullCommandLine: Bool) -> [String] {
        var arguments: [String] = []
        if fullCommandLine { arguments.append("-f") }
        arguments.append(pattern)
        let output = run("/usr/bin/pgrep", arguments: arguments).output
        return output.split(separator: "\n").map(String.init)
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
}
