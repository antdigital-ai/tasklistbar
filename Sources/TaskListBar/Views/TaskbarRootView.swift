import AppKit
import SwiftUI

enum TaskbarMetrics {
    static let barHeight: CGFloat = 36
    static let iconSize: CGFloat = 20
    static let appButtonWidth: CGFloat = 32
    static let trayHit: CGFloat = 22
    static let indicatorHeight: CGFloat = 2
    static let corner: CGFloat = 8
}

struct TaskbarTheme {
    static let hover = Color.primary.opacity(0.08)
    static let activeFill = Color.primary.opacity(0.12)
    static let hairline = Color.primary.opacity(0.14)
    static let chrome = Color.primary.opacity(0.08)
    static let footerFill = Color.primary.opacity(0.06)
}

struct TaskbarRootView: View {
    @ObservedObject var viewModel: TaskbarViewModel

    var body: some View {
        HStack(spacing: 4) {
            StartButton(isOpen: viewModel.isStartMenuOpen) {
                viewModel.toggleStartMenu()
            }

            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(width: 1, height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(viewModel.items) { item in
                        TaskbarAppButton(item: item) {
                            viewModel.select(item)
                        } pinAction: {
                            if item.isPinned {
                                viewModel.unpin(item)
                            } else {
                                viewModel.pin(item)
                            }
                        } quitAction: {
                            viewModel.quit(item)
                        }
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.55).combined(with: .opacity),
                                removal: .scale(scale: 0.55).combined(with: .opacity)
                            )
                        )
                    }
                }
                .animation(TaskbarMotion.list, value: viewModel.items.map(\.id))
            }

            Spacer(minLength: 6)

            SystemTrayView(
                battery: viewModel.batteryMonitor,
                spaces: viewModel.spacesMonitor,
                bluetooth: viewModel.bluetoothMonitor,
                volume: viewModel.volumeMonitor,
                clock: viewModel.clockModel,
                isCalendarOpen: viewModel.isCalendarOpen,
                onToggleCalendar: { viewModel.toggleCalendarPreview() }
            )
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(height: TaskbarMetrics.barHeight)
        .modifier(TaskbarPointerLock())
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(height: 0.5)
        }
    }
}

struct StartButton: View {
    let isOpen: Bool
    let action: () -> Void
    @Environment(\.taskbarAccent) private var accent
    @State private var hovering = false

    private let avatarSize: CGFloat = 22

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                avatar
                    .scaleEffect(hovering || isOpen ? 1.08 : 1.0)
                Capsule()
                    .fill(isOpen ? accent.color : Color.clear)
                    .frame(width: isOpen ? 14 : 0, height: TaskbarMetrics.indicatorHeight)
            }
            .frame(width: TaskbarMetrics.appButtonWidth, height: 28)
            .background(
                RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                    .fill(isOpen || hovering ? TaskbarTheme.activeFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous))
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
                    .frame(width: avatarSize, height: avatarSize)
            } else {
                ZStack {
                    Circle().fill(accent.color.opacity(0.92))
                    Text(CurrentUserProfile.initials)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.onAccent)
                }
                .frame(width: avatarSize, height: avatarSize)
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
    let action: () -> Void
    let pinAction: () -> Void
    let quitAction: () -> Void

    @Environment(\.taskbarAccent) private var accent
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: TaskbarMetrics.iconSize, height: TaskbarMetrics.iconSize)
                    .scaleEffect(hovering ? 1.12 : 1.0)
                Capsule()
                    .fill(item.isRunning ? (item.isActive ? accent.color : Color.primary.opacity(0.45)) : Color.clear)
                    .frame(width: item.isActive ? 14 : (item.isRunning ? 6 : 0), height: TaskbarMetrics.indicatorHeight)
                    .animation(TaskbarMotion.indicator, value: item.isActive)
                    .animation(TaskbarMotion.indicator, value: item.isRunning)
            }
            .frame(width: TaskbarMetrics.appButtonWidth, height: 28)
            .background(
                RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                    .fill(item.isActive || hovering ? TaskbarTheme.activeFill : Color.clear)
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(item.name)
        .contextMenu {
            Button(item.isPinned ? "从任务栏取消固定" : "固定到任务栏", action: pinAction)
            if item.isRunning {
                Divider()
                Button("退出 \(item.name)", action: quitAction)
            }
        }
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
