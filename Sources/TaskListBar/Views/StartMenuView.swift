import AppKit
import SwiftUI

struct StartMenuView: View {
    @ObservedObject var viewModel: TaskbarViewModel
    @ObservedObject private var catalog: StartMenuCatalog
    @FocusState private var searchFocused: Bool

    private let contentInset: CGFloat = 16
    private let appColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    private let folderColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
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
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.isStartMenuOpen) { open in
            if !open {
                searchFocused = false
            }
        }
    }

    private var content: some View {
        ZStack {
            if viewModel.showsAllApps {
                allAppsList
                    .transition(TaskbarMotion.pushTransition(forward: true))
            } else if catalog.isSearching {
                searchResultsGrid
                    .transition(.opacity)
            } else if let category = catalog.selectedCategory {
                categoryAppsGrid(category)
                    .id(category.rawValue)
                    .transition(TaskbarMotion.pushTransition(forward: true))
            } else {
                categoryLibrary
                    .transition(TaskbarMotion.pushTransition(forward: false))
            }
        }
        .clipped()
    }

    private var headerTitle: String {
        if viewModel.showsAllApps {
            return "全部应用"
        }
        if catalog.isSearching {
            return "搜索结果"
        }
        if let category = catalog.selectedCategory {
            return category.title
        }
        return "开始"
    }

    private var canGoBack: Bool {
        viewModel.showsAllApps || catalog.selectedCategory != nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            if canGoBack {
                Button {
                    withAnimation(TaskbarMotion.contentPop) {
                        viewModel.backToStartHome()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
                .help("返回")
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Text(headerTitle)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .animation(TaskbarMotion.contentPush, value: headerTitle)
            Spacer(minLength: 0)
            Button {
                viewModel.closeStartMenu()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        }
        .animation(TaskbarMotion.contentPop, value: canGoBack)
        .frame(height: 44, alignment: .center)
        .padding(.horizontal, contentInset)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.primary.opacity(0.55))
                .frame(width: 16, alignment: .center)
            TextField(
                viewModel.showsAllApps ? "搜索全部应用" : "搜索应用",
                text: $catalog.searchText
            )
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .focused($searchFocused)
            .onSubmit {
                if let app = catalog.filteredApps.first {
                    viewModel.launchFromStartMenu(app)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .padding(.horizontal, contentInset)
        .padding(.bottom, 12)
    }

    private var categoryLibrary: some View {
        ScrollView {
            if catalog.categoryGroups.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: folderColumns, alignment: .center, spacing: 16) {
                    ForEach(catalog.categoryGroups) { group in
                        CategoryFolderCard(group: group) {
                            withAnimation(TaskbarMotion.contentPush) {
                                catalog.openCategory(group.category)
                            }
                        }
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.vertical, 14)
            }
        }
    }

    private func categoryAppsGrid(_ category: AppCategory) -> some View {
        let apps = catalog.categoryGroups.first(where: { $0.category == category })?.apps
            ?? catalog.filteredApps.filter { $0.category == category }
        return ScrollView {
            if apps.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: appColumns, alignment: .center, spacing: 12) {
                    ForEach(apps) { app in
                        StartMenuAppCell(app: app) {
                            viewModel.launchFromStartMenu(app)
                        } pinAction: {
                            viewModel.pinFromStartMenu(app)
                        }
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.vertical, 12)
            }
        }
    }

    private var searchResultsGrid: some View {
        ScrollView {
            if catalog.filteredApps.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(catalog.categoryGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(group.category.title, systemImage: group.category.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            LazyVGrid(columns: appColumns, alignment: .center, spacing: 10) {
                                ForEach(group.apps) { app in
                                    StartMenuAppCell(app: app) {
                                        viewModel.launchFromStartMenu(app)
                                    } pinAction: {
                                        viewModel.pinFromStartMenu(app)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.vertical, 12)
            }
        }
    }

    private var allAppsList: some View {
        ScrollView {
            if catalog.filteredApps.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(catalog.categoryGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(group.category.title, systemImage: group.category.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)

                            ForEach(group.apps) { app in
                                StartMenuAppRow(app: app) {
                                    viewModel.launchFromStartMenu(app)
                                } pinAction: {
                                    viewModel.pinFromStartMenu(app)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, contentInset - 4)
                .padding(.vertical, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if catalog.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载应用…")
                    .foregroundStyle(.primary.opacity(0.55))
                    .font(.system(size: 13))
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28))
                    .foregroundStyle(.primary.opacity(0.35))
                Text(catalog.apps.isEmpty ? "暂无应用" : "没有匹配的应用")
                    .foregroundStyle(.primary.opacity(0.55))
                    .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let showingHome = viewModel.showsAllApps || catalog.selectedCategory != nil
            FooterIconButton(
                systemImage: showingHome ? "house.fill" : "square.grid.3x3.fill",
                help: showingHome ? "返回主页" : "全部应用",
                emphasized: showingHome
            ) {
                if showingHome {
                    withAnimation(TaskbarMotion.contentPop) {
                        viewModel.backToStartHome()
                    }
                } else {
                    withAnimation(TaskbarMotion.contentPush) {
                        viewModel.openAllApps()
                    }
                }
            }

            Spacer(minLength: 0)

            FooterIconButton(systemImage: "gearshape", help: "设置") {
                viewModel.openSettings()
            }
            FooterIconButton(systemImage: "keyboard", help: "修饰键") {
                viewModel.openModifierKeysSettings()
            }
            FooterIconButton(systemImage: "power", help: "退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, contentInset)
        .padding(.vertical, 10)
        .background(TaskbarTheme.footerFill.opacity(0.55))
    }
}

private struct FooterIconButton: View {
    let systemImage: String
    let help: String
    var emphasized: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = CurrentUserProfile.symbolImage(systemImage, size: 15) {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.primary.opacity(0.88))
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(emphasized || hovering ? 0.14 : 0.08))
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.92))
        .animation(TaskbarMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// App Library–style folder card with centered 2×2 icon collage.
struct CategoryFolderCard: View {
    let group: StartMenuCategoryGroup
    let action: () -> Void
    @State private var hovering = false

    private let folderSize: CGFloat = 92
    private let iconSize: CGFloat = 32
    private let iconGap: CGFloat = 6
    private let folderPadding: CGFloat = 11

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.18 : 0.10))

                    VStack(spacing: iconGap) {
                        HStack(spacing: iconGap) {
                            iconSlot(0)
                            iconSlot(1)
                        }
                        HStack(spacing: iconGap) {
                            iconSlot(2)
                            iconSlot(3)
                        }
                    }
                    .padding(folderPadding)
                }
                .frame(width: folderSize, height: folderSize)
                .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: hovering ? 8 : 0, y: hovering ? 3 : 0)

                VStack(spacing: 2) {
                    Text(group.category.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("\(group.apps.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.45))
                }
                .frame(width: folderSize, height: 32)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .scaleEffect(hovering ? 1.04 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.93))
        .animation(TaskbarMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help("\(group.category.title) · \(group.apps.count) 个")
    }

    @ViewBuilder
    private func iconSlot(_ index: Int) -> some View {
        if index < group.previewApps.count {
            Image(nsImage: group.previewApps[index].icon)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: iconSize, height: iconSize)
        }
    }
}

struct StartMenuAppCell: View {
    let app: StartMenuApp
    let action: () -> Void
    let pinAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .scaleEffect(hovering ? 1.08 : 1.0)
                Text(app.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? TaskbarTheme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.94))
        .animation(TaskbarMotion.hover, value: hovering)
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
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .scaleEffect(hovering ? 1.06 : 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(app.category.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 44, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? TaskbarTheme.hover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.97))
        .animation(TaskbarMotion.hover, value: hovering)
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
