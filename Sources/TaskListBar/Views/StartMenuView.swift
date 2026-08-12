import AppKit
import SwiftUI

struct StartMenuView: View {
    @ObservedObject var viewModel: TaskbarViewModel
    @ObservedObject private var catalog: StartMenuCatalog

    private let columns = [
        GridItem(.adaptive(minimum: 88, maximum: 110), spacing: 10)
    ]

    init(viewModel: TaskbarViewModel) {
        self.viewModel = viewModel
        self._catalog = ObservedObject(wrappedValue: viewModel.startMenuCatalog)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            Divider().opacity(0.25)
            if viewModel.showsAllApps {
                allAppsList
            } else {
                appGrid
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskbarTheme.menuTint)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if viewModel.showsAllApps {
                Button {
                    viewModel.backToStartHome()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("返回")
            }

            Text(viewModel.showsAllApps ? "全部应用" : "开始")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                viewModel.closeStartMenu()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.55))
            TextField(viewModel.showsAllApps ? "搜索全部应用" : "搜索应用", text: $catalog.searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var appGrid: some View {
        ScrollView {
            if catalog.filteredApps.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(catalog.filteredApps) { app in
                        StartMenuAppCell(app: app) {
                            viewModel.launchFromStartMenu(app)
                        } pinAction: {
                            viewModel.pinFromStartMenu(app)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var allAppsList: some View {
        ScrollView {
            if catalog.filteredApps.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(catalog.filteredApps) { app in
                        StartMenuAppRow(app: app) {
                            viewModel.launchFromStartMenu(app)
                        } pinAction: {
                            viewModel.pinFromStartMenu(app)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.35))
            Text(catalog.apps.isEmpty ? "正在扫描应用…" : "没有匹配的应用")
                .foregroundStyle(.white.opacity(0.55))
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if viewModel.showsAllApps {
                    viewModel.backToStartHome()
                } else {
                    viewModel.openAllApps()
                }
            } label: {
                Label(
                    viewModel.showsAllApps ? "返回主页" : "全部应用",
                    systemImage: viewModel.showsAllApps ? "house" : "square.grid.3x3.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(viewModel.showsAllApps ? 0.14 : 0.10))
                )
            }
            .buttonStyle(.plain)
            .help(viewModel.showsAllApps ? "返回开始主页" : "查看全部应用")

            Spacer()

            Text("\(catalog.filteredApps.count) 个")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))

            Button {
                viewModel.openModifierKeysSettings()
            } label: {
                Label("修饰键", systemImage: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("切换修饰键（Windows 键盘）")

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18))
    }
}

struct StartMenuAppCell: View {
    let app: StartMenuApp
    let action: () -> Void
    let pinAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                Text(app.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? TaskbarTheme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("打开", action: action)
            Button("固定到任务栏", action: pinAction)
            Divider()
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
        }
        .help(app.name)
    }
}

struct StartMenuAppRow: View {
    let app: StartMenuApp
    let action: () -> Void
    let pinAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? TaskbarTheme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("打开", action: action)
            Button("固定到任务栏", action: pinAction)
            Divider()
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
        }
        .help(app.name)
    }
}
