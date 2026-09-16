import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorktreeTrayButton: View {
    @ObservedObject var boost: BoostService
    var isOpen = false
    var onToggle: (() -> Void)?
    @Environment(\.taskbarAccent) private var accent
    @State private var hovering = false
    @State private var justCleaned = false
    @State private var cleanFlashTask: Task<Void, Never>?

    var body: some View {
        Button {
            onToggle?()
        } label: {
            TraySymbol(
                name: "arrow.triangle.branch",
                color: justCleaned ? accent.color : Color.primary.opacity(hovering ? 0.98 : 0.88),
                isHighlighted: isOpen || hovering,
                weight: .medium
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .onChange(of: boost.snapshot.generation) { _ in
            guard boost.snapshot.kind == .worktree else { return }
            flashCleaned()
        }
    }

    private func flashCleaned() {
        cleanFlashTask?.cancel()
        justCleaned = true
        cleanFlashTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            justCleaned = false
        }
    }
}

private enum CleanerLayout {
    static let width: CGFloat = 480
    static let height: CGFloat = 420
    static let corner: CGFloat = 10
    static let contentMargin: CGFloat = 20
    static let contentTop: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let controlSpacing: CGFloat = 8
    static let titleBarHeight: CGFloat = 52
    static let trafficLeading: CGFloat = 8
    static let trafficSize: CGFloat = 12
    static let trafficGap: CGFloat = 8
    static let toolbarSpacing: CGFloat = 8
    static let groupCorner: CGFloat = 6
    static let groupInner: CGFloat = 10
    static let rowVertical: CGFloat = 6
}

struct BoostFlyout: View {
    enum Metrics {
        static let width = CleanerLayout.width
        static let height = CleanerLayout.height
        static let corner = CleanerLayout.corner
    }

    @ObservedObject var boost: BoostService
    let onClose: () -> Void
    @State private var groups: [BoostService.ProcessGroup] = []
    @State private var disks: [BoostService.DiskItem] = []
    @State private var selected: Set<String> = []
    @State private var didScan = false
    @State private var didScanDisk = false

    private var selectedCount: Int {
        groups.filter { selected.contains($0.label) }.reduce(0) { $0 + $1.count }
    }

    private var selectedBytes: Int64 {
        disks.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    private var canClean: Bool {
        !boost.isRunning && (selectedCount > 0 || selectedBytes > 0)
    }

    private var subtitle: String {
        if !didScan { return "Scanning" }
        if groups.isEmpty && disks.isEmpty && didScanDisk { return "No items" }
        var parts: [String] = []
        if !groups.isEmpty { parts.append("\(groups.reduce(0) { $0 + $1.count }) processes") }
        if !disks.isEmpty { parts.append(BoostService.formatBytes(disks.reduce(0) { $0 + $1.bytes })) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        CleanerWindowChrome(
            title: "Boost Cleaner",
            subtitle: subtitle,
            onClose: onClose,
            canClean: canClean,
            onClean: {
                let chosenGroups = groups.filter { selected.contains($0.label) }
                let chosenDisks = disks.filter { selected.contains($0.id) }
                boost.boost(groups: chosenGroups, disks: chosenDisks)
                onClose()
            },
            onRefresh: { reload(force: true) }
        ) {
            if !didScan {
                CleanerLoading(text: "Scanning…")
            } else if groups.isEmpty && disks.isEmpty && didScanDisk {
                CleanerEmptyState(
                    title: "Nothing to Clean",
                    subtitle: "No development processes or Node caches found.",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: CleanerLayout.sectionSpacing) {
                        if !groups.isEmpty {
                            CleanerSection("Processes") {
                                ForEach(groups) { group in
                                    CleanerRow(
                                        title: group.label,
                                        accessory: "\(group.count)",
                                        isOn: binding(for: group.label)
                                    )
                                }
                            }
                        }
                        if !disks.isEmpty {
                            CleanerSection("Disk") {
                                ForEach(disks) { item in
                                    CleanerRow(
                                        title: item.label,
                                        subtitle: item.detail,
                                        accessory: BoostService.formatBytes(item.bytes),
                                        isOn: binding(for: item.id)
                                    )
                                }
                            }
                        } else if !didScanDisk {
                            CleanerLoading(text: "Calculating disk usage…")
                        }
                    }
                    .padding(.horizontal, CleanerLayout.contentMargin)
                    .padding(.top, CleanerLayout.contentTop)
                    .padding(.bottom, CleanerLayout.contentMargin)
                }
            }
        }
        .onAppear { reload(force: false) }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func reload(force: Bool = false) {
        let hasProcessCache = !boost.lastGroups.isEmpty
        let hasDiskCache = boost.disksCached
        if force || !hasProcessCache { didScan = false }
        if force || !hasDiskCache {
            didScanDisk = false
            if force { disks = [] }
        } else {
            disks = boost.lastDisks
            didScanDisk = true
        }
        if hasProcessCache && !force {
            groups = boost.lastGroups
            selected = Set(groups.map(\.label) + disks.filter(\.selectedByDefault).map(\.id))
            didScan = true
        }
        Task { @MainActor in
            async let processScan = boost.scan(force: force)
            async let diskScan = boost.scanDisk(force: force)
            let processResult = await processScan
            groups = processResult
            selected = Set(processResult.map(\.label))
            didScan = true
            let diskResult = await diskScan
            disks = diskResult
            selected.formUnion(diskResult.filter(\.selectedByDefault).map(\.id))
            didScanDisk = true
        }
    }
}

struct WorktreeFlyout: View {
    enum Metrics {
        static let width: CGFloat = 640
        static let height = CleanerLayout.height
        static let corner = CleanerLayout.corner
        static let sidebar: CGFloat = 200
    }

    @ObservedObject var boost: BoostService
    let onClose: () -> Void
    @State private var repoPath = ""
    @State private var items: [BoostService.WorktreeItem] = []
    @State private var selected: Set<String> = []
    @State private var didScan = false
    @State private var repoError: String?

    private var repos: [BoostService.RecentRepo] { boost.lastRecentRepos }
    private var didScanRepos: Bool { boost.recentReposCached }

    private var sidebarRepos: [BoostService.RecentRepo] {
        guard !repoPath.isEmpty else { return repos }
        if repos.contains(where: { $0.url.path == repoPath }) { return repos }
        let url = URL(fileURLWithPath: repoPath)
        return [
            BoostService.RecentRepo(
                url: url,
                name: url.lastPathComponent,
                sources: ["Chosen"],
                lastActive: Date(),
                worktreeCount: items.count
            )
        ] + repos
    }

    private var selectedItems: [BoostService.WorktreeItem] {
        items.filter { selected.contains($0.id) }
    }

    private var canClean: Bool {
        !boost.isRunning && !selectedItems.isEmpty
    }

    private var repoName: String {
        URL(fileURLWithPath: repoPath).lastPathComponent
    }

    private var subtitle: String {
        if repoPath.isEmpty {
            return repos.isEmpty ? "Recent projects" : "\(repos.count) recent projects"
        }
        return repoName
    }

    var body: some View {
        CleanerWindowChrome(
            title: "Worktree Cleaner",
            subtitle: subtitle,
            onClose: onClose,
            canClean: canClean,
            onClean: {
                boost.cleanWorktrees(selectedItems)
                onClose()
            },
            onRefresh: { reload(force: true) },
            onChoose: chooseRepository,
            onSmartSelect: repoPath.isEmpty ? nil : {
                selected = Set(items.filter(\.selectedByDefault).map(\.id))
            }
        ) {
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1)
                detail
            }
        }
        .onAppear {
            boost.prefetchRecentRepos()
            selectFirstRepoIfNeeded()
        }
        .onChange(of: boost.lastRecentRepos) { _ in
            selectFirstRepoIfNeeded()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.45))
                .padding(.horizontal, 16)
                .padding(.top, CleanerLayout.contentTop)
                .padding(.bottom, 6)

            if !didScanRepos {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sidebarRepos.isEmpty {
                Text("No recent projects")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sidebarRepos) { repo in
                            sidebarRow(repo)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, CleanerLayout.contentMargin)
                }
            }
        }
        .frame(width: Metrics.sidebar)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.96))
    }

    private func sidebarRow(_ repo: BoostService.RecentRepo) -> some View {
        let isSelected = repo.url.path == repoPath
        return Button {
            selectRepo(repo.url.path)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.black.opacity(0.90))
                    .lineLimit(1)
                Text(repo.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.black.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        ZStack(alignment: .bottomLeading) {
            if repoPath.isEmpty {
                if !didScanRepos {
                    CleanerLoading(text: "Looking up recent projects…")
                } else {
                    CleanerEmptyState(
                        title: "Select a Project",
                        subtitle: "Choose a git repository in the sidebar to list its linked worktrees.",
                        actionTitle: "Choose Repository…",
                        action: chooseRepository
                    )
                }
            } else if !didScan {
                CleanerLoading(text: "Scanning…")
            } else if items.isEmpty {
                CleanerEmptyState(
                    title: "No Linked Worktrees",
                    subtitle: "This repository has no linked worktrees to clean.",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                ScrollView {
                    CleanerSection(repoName) {
                        ForEach(items) { item in
                            CleanerRow(
                                title: item.name,
                                subtitle: item.detail,
                                accessory: BoostService.formatBytes(item.bytes),
                                isOn: binding(for: item.id)
                            )
                            .contextMenu {
                                Button("Show in Finder") {
                                    boost.reveal(item.url)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, CleanerLayout.contentMargin)
                    .padding(.top, CleanerLayout.contentTop)
                    .padding(.bottom, CleanerLayout.contentMargin)
                }
            }

            if let repoError {
                Text(repoError)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.86, green: 0.24, blue: 0.22))
                    .padding(.horizontal, CleanerLayout.contentMargin)
                    .padding(.bottom, CleanerLayout.contentMargin)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private func selectFirstRepoIfNeeded() {
        guard repoPath.isEmpty, let first = repos.first else { return }
        selectRepo(first.url.path)
    }

    private func selectRepo(_ path: String) {
        guard repoPath != path else { return }
        repoPath = path
        repoError = nil
        items = []
        selected = []
        reload(force: true)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a git repository to list its linked worktrees."
        panel.prompt = "Choose"
        panel.directoryURL = repoPath.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            : URL(fileURLWithPath: repoPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let repo = BoostService.resolvedGitRepo(at: url) else {
            repoError = "This folder is not a Git repository."
            return
        }
        repoError = nil
        items = []
        selected = []
        repoPath = repo.path
        reload(force: true)
    }

    private func reload(force: Bool) {
        if force {
            boost.prefetchRecentRepos()
            Task { _ = await boost.scanRecentRepos(force: true) }
        }
        if repoPath.isEmpty {
            items = []
            selected = []
            didScan = true
            return
        }
        if force || !boost.worktreesCached {
            didScan = false
        } else if !boost.lastWorktrees.isEmpty {
            items = boost.lastWorktrees
            selected = Set(items.filter(\.selectedByDefault).map(\.id))
            didScan = true
        }
        Task { @MainActor in
            let next = await boost.scanWorktrees(repoPath: repoPath, force: force)
            items = next
            selected = Set(next.filter(\.selectedByDefault).map(\.id))
            didScan = true
        }
    }
}

private struct CleanerWindowChrome<Content: View>: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void
    var canClean = false
    var onClean: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onChoose: (() -> Void)?
    var onSmartSelect: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .clipShape(RoundedRectangle(cornerRadius: CleanerLayout.corner, style: .continuous))
    }

    private var titleBar: some View {
        HStack(spacing: 0) {
            WindowTrafficLights(onClose: onClose)
                .padding(.leading, CleanerLayout.trafficLeading)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
            .padding(.leading, CleanerLayout.controlSpacing)

            Spacer(minLength: 16)

            HStack(spacing: CleanerLayout.toolbarSpacing) {
                if onClean != nil {
                    CleanerToolbarIcon(symbol: "trash", enabled: canClean, action: { onClean?() })
                }
                if onSmartSelect != nil {
                    CleanerToolbarIcon(symbol: "sparkles", enabled: true, action: { onSmartSelect?() })
                }
                if onRefresh != nil {
                    CleanerToolbarIcon(symbol: "arrow.clockwise", enabled: true, action: { onRefresh?() })
                }
                if onChoose != nil {
                    CleanerToolbarIcon(symbol: "folder", enabled: true, action: { onChoose?() })
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: CleanerLayout.titleBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
    }
}

private struct WindowTrafficLights: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: CleanerLayout.trafficGap) {
            Circle()
                .fill(Color(red: 1, green: 0.373, blue: 0.341))
                .frame(width: CleanerLayout.trafficSize, height: CleanerLayout.trafficSize)
                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                .onTapGesture(perform: onClose)
            Circle()
                .fill(Color(red: 1, green: 0.737, blue: 0.188))
                .frame(width: CleanerLayout.trafficSize, height: CleanerLayout.trafficSize)
                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            Circle()
                .fill(Color(red: 0.153, green: 0.788, blue: 0.251))
                .frame(width: CleanerLayout.trafficSize, height: CleanerLayout.trafficSize)
                .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
        }
        .frame(width: 52, alignment: .leading)
    }
}

private struct CleanerToolbarIcon: View {
    let symbol: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.black.opacity(enabled ? 0.68 : 0.28))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct CleanerEmptyState: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: CleanerLayout.controlSpacing) {
            GitBranchMark()
                .stroke(Color.black.opacity(0.42), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .frame(width: 32, height: 36)
                .padding(.bottom, 4)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.92))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color.black.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitBranchMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        let stemTop = rect.minY + rect.height * 0.42
        path.move(to: CGPoint(x: midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: midX, y: stemTop))
        path.move(to: CGPoint(x: midX, y: stemTop))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 2, y: rect.minY + 4),
            control: CGPoint(x: midX - 1, y: rect.minY + 10)
        )
        path.move(to: CGPoint(x: midX, y: stemTop))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 2, y: rect.minY + 4),
            control: CGPoint(x: midX + 1, y: rect.minY + 10)
        )
        return path
    }
}

private struct CleanerSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CleanerLayout.controlSpacing) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, CleanerLayout.groupInner)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: CleanerLayout.groupCorner, style: .continuous)
                    .fill(Color.black.opacity(0.04))
            )
        }
    }
}

private struct CleanerRow: View {
    let title: String
    var subtitle: String? = nil
    let accessory: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .center, spacing: CleanerLayout.controlSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.black.opacity(0.90))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.black.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: CleanerLayout.controlSpacing)
                Text(accessory)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.black.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, CleanerLayout.rowVertical)
    }
}

private struct CleanerLoading: View {
    let text: String

    var body: some View {
        VStack(spacing: CleanerLayout.controlSpacing) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.black.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
