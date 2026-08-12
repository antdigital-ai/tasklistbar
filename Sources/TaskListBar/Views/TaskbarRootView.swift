import AppKit
import SwiftUI

enum TaskbarMetrics {
    static let barHeight: CGFloat = 36
    static let iconSize: CGFloat = 20
    static let appButtonWidth: CGFloat = 32
    static let trayHit: CGFloat = 22
    static let indicatorHeight: CGFloat = 2
    static let corner: CGFloat = 4
}

struct TaskbarTheme {
    /// Keep tint light so NSVisualEffectView blur stays visible.
    static let barTint = Color.black.opacity(0.18)
    static let barBorder = Color.white.opacity(0.10)
    static let accent = Color(red: 0.20, green: 0.55, blue: 0.95)
    static let startButton = Color(red: 0.12, green: 0.45, blue: 0.85).opacity(0.90)
    static let hover = Color.white.opacity(0.12)
    static let activeFill = Color.white.opacity(0.16)
    static let menuTint = Color.black.opacity(0.22)
}

struct TaskbarRootView: View {
    @ObservedObject var viewModel: TaskbarViewModel

    var body: some View {
        HStack(spacing: 4) {
            StartButton(isOpen: viewModel.isStartMenuOpen) {
                viewModel.toggleStartMenu()
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
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
                    }
                }
            }

            Spacer(minLength: 6)

            SystemTrayView(
                battery: viewModel.batteryMonitor,
                spaces: viewModel.spacesMonitor,
                trash: viewModel.trashMonitor,
                clock: viewModel.clockModel
            )
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskbarTheme.barTint)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TaskbarTheme.barBorder)
                .frame(height: 0.5)
        }
    }
}

struct StartButton: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("开始")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                    .fill(isOpen || hovering ? TaskbarTheme.startButton : TaskbarTheme.startButton.opacity(0.82))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("开始菜单")
    }
}

struct TaskbarAppButton: View {
    let item: TaskbarAppItem
    let action: () -> Void
    let pinAction: () -> Void
    let quitAction: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: TaskbarMetrics.iconSize, height: TaskbarMetrics.iconSize)
                Capsule()
                    .fill(item.isRunning ? (item.isActive ? TaskbarTheme.accent : Color.white.opacity(0.50)) : Color.clear)
                    .frame(width: item.isActive ? 14 : 6, height: TaskbarMetrics.indicatorHeight)
            }
            .frame(width: TaskbarMetrics.appButtonWidth, height: 28)
            .background(
                RoundedRectangle(cornerRadius: TaskbarMetrics.corner, style: .continuous)
                    .fill(item.isActive || hovering ? TaskbarTheme.activeFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = emphasized
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = emphasized
    }
}

import AppKit

/// Hosting view that accepts the first click even when the app is inactive.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> where Content: View {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }
}

enum GlassPanelFactory {
    static func wrap<Content: View>(
        _ rootView: Content,
        material: NSVisualEffectView.Material = .menu
    ) -> NSVisualEffectView {
        let hosting = FirstMouseHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]

        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        effect.wantsLayer = true
        hosting.frame = effect.bounds
        effect.addSubview(hosting)
        return effect
    }
}
