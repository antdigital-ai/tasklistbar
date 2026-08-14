import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FavoritesStripView: View {
    @ObservedObject var store: FavoritesStore
    @ObservedObject var settings: AppSettings
    let onPinApp: (String) -> Void
    @Environment(\.taskbarSize) private var size
    @State private var dropTargeted = false

    private var isVisible: Bool {
        settings.showDesktopFavorite || settings.showTrashFavorite || !store.bookmarks.isEmpty
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 4) {
            HStack(spacing: 2) {
                if settings.showDesktopFavorite {
                    FavoriteButton(
                        icon: store.desktopIcon(),
                        help: "桌面",
                        action: store.openDesktop
                    ) {
                        Button("打开桌面", action: store.openDesktop)
                    }
                }

                if settings.showTrashFavorite {
                    FavoriteButton(
                        icon: store.trashIcon(),
                        help: store.isTrashFull ? "废纸篓（有内容）" : "废纸篓",
                        action: store.openTrash
                    ) {
                        Button("打开废纸篓", action: store.openTrash)
                        Button("清倒废纸篓", action: store.emptyTrash)
                    }
                }

                ForEach(store.bookmarks) { bookmark in
                    FavoriteButton(
                        icon: store.icon(for: bookmark),
                        help: bookmark.name,
                        action: { store.open(bookmark) }
                    ) {
                        Button("打开") { store.open(bookmark) }
                        Button("在 Finder 中显示") { store.reveal(bookmark) }
                        Divider()
                        Button("从收藏移除") { store.remove(bookmark.id) }
                    }
                    .onDrag {
                        NSItemProvider(object: bookmark.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        handleReorder(providers, onto: bookmark.id)
                    }
                }
            }
            .padding(dropTargeted ? 1 : 0)
            .background(
                RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                    .fill(dropTargeted ? TaskbarTheme.hover : Color.clear)
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleFileDrop(providers)
            }

            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(width: 1, height: size.dividerHeight)
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let raw = item as? URL {
                    url = raw
                } else if let path = item as? String {
                    url = URL(fileURLWithPath: path)
                } else {
                    url = nil
                }
                guard let url else { return }
                Task { @MainActor in
                    if url.pathExtension.lowercased() == "app",
                       let bid = Bundle(url: url)?.bundleIdentifier {
                        onPinApp(bid)
                    } else {
                        store.add(url: url)
                    }
                }
            }
        }
        return true
    }

    private func handleReorder(_ providers: [NSItemProvider], onto target: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let raw: String?
            if let data = item as? Data {
                raw = String(data: data, encoding: .utf8)
            } else {
                raw = item as? String
            }
            guard let raw, let dragged = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            Task { @MainActor in
                store.reorder(draggedID: dragged, targetID: target)
            }
        }
        return true
    }
}

private struct FavoriteButton<Menu: View>: View {
    let icon: NSImage
    let help: String
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu

    @Environment(\.taskbarSize) private var size
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size.iconSize, height: size.iconSize)
                .scaleEffect(hovering ? 1.12 : 1.0)
                .frame(width: size.appButtonWidth, height: size.appButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: size.corner, style: .continuous)
                        .fill(hovering ? TaskbarTheme.activeFill : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: size.corner, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        .onHover { hovering in
            withAnimation(TaskbarMotion.hover) {
                self.hovering = hovering
            }
        }
        .help(help)
        .contextMenu(menuItems: menu)
    }
}
