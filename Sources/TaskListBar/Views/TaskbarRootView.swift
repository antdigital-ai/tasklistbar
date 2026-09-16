import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TaskbarMetrics {
    static var size: TaskbarSize = .regular

    static var barHeight: CGFloat { size.barHeight }
    static var iconSize: CGFloat { size.iconSize }
    static var appButtonWidth: CGFloat { size.appButtonWidth }
    static var appButtonHeight: CGFloat { size.appButtonHeight }
    static var trayHit: CGFloat { size.trayHit }
    static var indicatorHeight: CGFloat { size.indicatorHeight }
    static var corner: CGFloat { size.corner }
}

struct TaskbarTheme {
    static let hover = Color.primary.opacity(0.08)
    static let activeFill = Color.primary.opacity(0.12)
    static let hairline = Color.primary.opacity(0.14)
    static let chrome = Color.primary.opacity(0.08)
    static let footerFill = Color.primary.opacity(0.06)
}

private extension View {
    func trayContextMenu(viewModel: TaskbarViewModel) -> some View {
        contextMenu {
            Button {
                viewModel.openActivityMonitor()
            } label: {
                Label("活动监视器", systemImage: "chart.bar.xaxis")
            }
            Button {
                viewModel.openSettings()
            } label: {
                Label("任务栏设置", systemImage: "gearshape")
            }
        }
    }
}

struct TaskbarRootView: View {
    @ObservedObject var viewModel: TaskbarViewModel
    @Environment(\.taskbarSize) private var size

    var body: some View {
        HStack(spacing: 4) {
            StartButton(isOpen: viewModel.isStartMenuOpen) {
                viewModel.toggleStartMenu()
            }

            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(width: 1, height: size.dividerHeight)

            FavoritesStripView(
                store: viewModel.favoritesStore,
                settings: viewModel.appSettings,
                onPinApp: { viewModel.pinnedStore.pin($0) }
            )

            TaskbarAppStrip(viewModel: viewModel)

            Spacer(minLength: 6)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    viewModel.handleTaskbarFileDrop(providers)
                }

            SystemTrayView(
                battery: viewModel.batteryMonitor,
                boost: viewModel.boostService,
                spaces: viewModel.spacesMonitor,
                bluetooth: viewModel.bluetoothMonitor,
                volume: viewModel.volumeMonitor,
                clock: viewModel.clockModel,
                isCalendarOpen: viewModel.isCalendarOpen,
                isBoostOpen: viewModel.isBoostOpen,
                isWorktreeOpen: viewModel.isWorktreeOpen,
                onToggleCalendar: { viewModel.toggleCalendarPreview() },
                onToggleBoost: { viewModel.toggleBoostCleanup() },
                onToggleWorktree: { viewModel.toggleWorktreeCleanup() },
                onShowDesktop: { viewModel.toggleShowDesktop() }
            )
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: size.barHeight)
        .contentShape(Rectangle())
        .animation(TaskbarMotion.sizeChange, value: size)
        .modifier(TaskbarPointerLock())
        .trayContextMenu(viewModel: viewModel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(height: 0.5)
        }
    }
}

private struct AppStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AppStripViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct TaskbarAppStrip: View {
    @ObservedObject var viewModel: TaskbarViewModel
    @Environment(\.taskbarSize) private var size
    @StateObject private var scroll = StripScrollState()
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var dropTargeted = false
    @State private var dropTargetID: String?
    @State private var scrollMonitor: Any?

    private var overflow: CGFloat { max(0, contentWidth - viewportWidth) }
    private var offset: CGFloat {
        min(0, max(-overflow, scroll.offset))
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(viewModel.items) { item in
                TaskbarAppButton(item: item, isDropTarget: dropTargetID == item.iconReorderID) {
                    viewModel.select(item)
                } pinAction: {
                    if item.isPinned {
                        viewModel.unpin(item)
                    } else {
                        viewModel.pin(item)
                    }
                } revealAction: {
                    viewModel.revealPinnedFolder(item)
                } quitAction: {
                    viewModel.quit(item)
                } closeWindowAction: {
                    viewModel.closeWindow(item)
                }
                .onDrag {
                    NSItemProvider(object: item.iconReorderID as NSString)
                }
                .onDrop(of: [.text, .fileURL], isTargeted: dropBinding(for: item.iconReorderID)) { providers in
                    handleDrop(providers, onto: item)
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.55).combined(with: .opacity),
                        removal: .scale(scale: 0.55).combined(with: .opacity)
                    )
                )
            }
        }
        .animation(TaskbarMotion.list, value: viewModel.pinnedStore.items.map(\.id))
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AppStripWidthKey.self, value: geo.size.width)
            }
        )
        .offset(x: offset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: AppStripViewportKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(AppStripWidthKey.self) { contentWidth = $0 }
        .onPreferenceChange(AppStripViewportKey.self) { width in
            viewportWidth = width
            viewModel.updateStripWidth(width)
        }
        .onChange(of: viewModel.items.map(\.id)) { _ in clampOffset() }
        .onChange(of: overflow) { _ in clampOffset() }
        .onHover { hovering in
            updateScrollMonitor(hovering)
        }
        .onDisappear { updateScrollMonitor(false) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            viewModel.handleTaskbarFileDrop(providers)
        }
        .padding(dropTargeted ? 1 : 0)
        .background(
            RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                .fill(dropTargeted ? TaskbarTheme.hover : Color.clear)
        )
        .trayContextMenu(viewModel: viewModel)
    }

    private func dropBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetID == id },
            set: { dropTargetID = $0 ? id : (dropTargetID == id ? nil : dropTargetID) }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider], onto item: TaskbarAppItem) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            return handleReorder(providers, onto: item.iconReorderID)
        }
        return viewModel.handleTaskbarFileDrop(providers, before: item.iconReorderID)
    }

    private func handleReorder(_ providers: [NSItemProvider], onto targetID: String) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let raw: String?
            if let data = item as? Data {
                raw = String(data: data, encoding: .utf8)
            } else {
                raw = item as? String
            }
            guard let dragged = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !dragged.isEmpty else { return }
            Task { @MainActor in
                viewModel.reorderIcons(draggedID: dragged, onto: targetID)
            }
        }
        return true
    }

    private func clampOffset() {
        scroll.offset = min(0, max(-overflow, scroll.offset))
    }

    private func updateScrollMonitor(_ hovering: Bool) {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard hovering else { return }
        let state = scroll
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let overflow = max(0, contentWidth - viewportWidth)
            guard overflow > 0 else { return event }
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard abs(delta) > 0.2 else { return event }
            state.offset = min(0, max(-overflow, state.offset + delta * 2))
            return nil
        }
    }
}

private final class StripScrollState: ObservableObject {
    @Published var offset: CGFloat = 0
}

struct StartButton: View {
    let isOpen: Bool
    let action: () -> Void
    @Environment(\.taskbarAccent) private var accent
    @Environment(\.taskbarSize) private var size
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                avatar
                Capsule()
                    .fill(isOpen ? accent.color : Color.clear)
                    .frame(width: isOpen ? size.indicatorActiveWidth : 0, height: size.indicatorHeight)
            }
            .frame(width: size.appButtonWidth, height: size.appButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                    .fill(isOpen || hovering ? TaskbarTheme.activeFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: size.corner, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help("开始菜单 · \(CurrentUserProfile.displayName)")
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let image = CurrentUserProfile.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.avatarSize, height: size.avatarSize)
            } else {
                ZStack {
                    Circle().fill(accent.color.opacity(0.92))
                    Text(CurrentUserProfile.initials)
                        .font(.system(size: size.avatarInitials, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.onAccent)
                }
                .frame(width: size.avatarSize, height: size.avatarSize)
            }
        }
        .clipShape(Circle())
        .overlay(
            Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
        )
    }
}

struct TaskbarAppButton: View {
    let item: TaskbarAppItem
    var isDropTarget = false
    let action: () -> Void
    let pinAction: () -> Void
    var revealAction: (() -> Void)?
    let quitAction: () -> Void
    var closeWindowAction: (() -> Void)?

    @Environment(\.taskbarAccent) private var accent
    @Environment(\.taskbarSize) private var size
    @State private var hovering = false

    private var helpText: String {
        if let title = item.windowTitle, !title.isEmpty, !item.isGrouped {
            return "\(item.name) — \(title)"
        }
        if item.windowCount > 1 {
            return "\(item.name) · \(item.windowCount) 个窗口"
        }
        return item.name
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .bottom) {
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.iconSize, height: size.iconSize)
                        if let badge = item.badge, badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: size.badgeFont, weight: .bold, design: .rounded))
                                .foregroundStyle(item.badgeIsUnread ? Color.white : Color.primary.opacity(0.92))
                                .padding(.horizontal, badge > 9 ? 3 : 2)
                                .padding(.vertical, 0.5)
                                .background(Capsule().fill(item.badgeIsUnread ? Color.red.opacity(0.92) : Color.primary.opacity(0.16)))
                                .offset(x: 4, y: -3)
                        }
                    }
                    .overlay {
                        if item.isUnresponsive {
                            HungHatch()
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }

                    if let progress = item.progress, progress > 0, progress < 1 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.18))
                                Capsule()
                                    .fill(accent.color)
                                    .frame(width: max(2, geo.size.width * progress))
                            }
                        }
                        .frame(width: size.iconSize, height: 2)
                        .offset(y: 1)
                    }
                }

                Capsule()
                    .fill(item.isRunning ? (item.isActive ? accent.color : Color.primary.opacity(0.45)) : Color.clear)
                    .frame(
                        width: item.isActive ? size.indicatorActiveWidth : (item.isRunning ? size.indicatorRunningWidth : 0),
                        height: size.indicatorHeight
                    )
                    .animation(TaskbarMotion.indicator, value: item.isActive)
                    .animation(TaskbarMotion.indicator, value: item.isRunning)
            }
            .frame(width: size.appButtonWidth, height: size.appButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                    .fill(item.isActive || hovering || isDropTarget ? TaskbarTheme.activeFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: size.corner, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(helpText)
        .contextMenu {
            if item.isFolder {
                Button("打开", action: action)
                Button("在 Finder 中显示") { revealAction?() }
                Divider()
                Button("从任务栏取消固定", action: pinAction)
            } else {
                Button(item.isPinned ? "从任务栏取消固定" : "固定到任务栏", action: pinAction)
                if item.windowID != nil {
                    Button("关闭窗口") { closeWindowAction?() }
                }
                if item.isRunning {
                    Divider()
                    Button("退出 \(item.name)", action: quitAction)
                }
            }
        }
    }
}

private struct HungHatch: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3.5
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(.red.opacity(0.55)), lineWidth: 1.1)
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hosting view that accepts the first click even when the app is inactive.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> where Content: View {
    var locksArrowCursor = false

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        if locksArrowCursor {
            addCursorRect(bounds, cursor: .arrow)
        } else {
            super.resetCursorRects()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if locksArrowCursor {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
    }
}

enum SolidWindowFactory {
    static func wrap<Content: View>(
        _ rootView: Content,
        cornerRadius: CGFloat
    ) -> NSView {
        let hosting = FirstMouseHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = true
        hosting.layer?.backgroundColor = NSColor.white.cgColor
        hosting.layer?.cornerRadius = cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        return hosting
    }
}

enum GlassPanelFactory {
    /// Native macOS glass: Liquid Glass on 26+, vibrancy fallback earlier.
    static func wrap<Content: View>(
        _ rootView: Content,
        cornerRadius: CGFloat = 0,
        lockArrowCursor: Bool = false
    ) -> NSView {
        let hosting = FirstMouseHostingView(rootView: rootView.background(Color.clear))
        hosting.locksArrowCursor = lockArrowCursor
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.clipsToBounds = cornerRadius > 0
            glass.wantsLayer = true
            glass.layer?.isOpaque = false
            glass.layer?.masksToBounds = cornerRadius > 0
            glass.contentView = hosting
            if let content = glass.contentView {
                content.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                    content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                    content.topAnchor.constraint(equalTo: glass.topAnchor),
                    content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
                ])
            }
            return glass
        }

        hosting.translatesAutoresizingMaskIntoConstraints = false
        let effect = NSVisualEffectView()
        effect.material = cornerRadius > 0 ? .popover : .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.wantsLayer = true
        if cornerRadius > 0 {
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
        }
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        return effect
    }
}
