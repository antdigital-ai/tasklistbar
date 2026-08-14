import AppKit
import Combine
import Foundation

struct FavoriteBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var bookmark: Data
    var isFolder: Bool
}

@MainActor
final class FavoritesStore: ObservableObject {
    private let defaultsKey = "favoriteBookmarks"
    private static let promptedKey = "didPromptFullDiskAccess"

    @Published private(set) var bookmarks: [FavoriteBookmark] = []
    @Published private(set) var isTrashFull = false

    private var trashTask: Task<Void, Never>?
    private var didPromptFDA = UserDefaults.standard.bool(forKey: FavoritesStore.promptedKey)

    static var desktopURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    init() {
        load()
    }

    func start() {
        refreshTrashState()
        trashTask?.cancel()
        trashTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refreshTrashState()
                }
            }
        }
    }

    func stop() {
        trashTask?.cancel()
        trashTask = nil
    }

    func add(url: URL) {
        if url.pathExtension.lowercased() == "app" { return }
        if contains(url: url) { return }
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            bookmarks.append(
                FavoriteBookmark(
                    id: UUID(),
                    name: url.lastPathComponent,
                    bookmark: data,
                    isFolder: isDirectory.boolValue || url.hasDirectoryPath
                )
            )
            save()
        } catch {
            AppLog.warn("收藏失败 \(url.lastPathComponent): \(error.localizedDescription)", category: "favorites")
        }
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func reorder(draggedID: UUID, targetID: UUID) {
        guard let from = bookmarks.firstIndex(where: { $0.id == draggedID }),
              let to = bookmarks.firstIndex(where: { $0.id == targetID }),
              from != to
        else { return }
        bookmarks.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    func resolvedURL(for bookmark: FavoriteBookmark) -> URL? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            return nil
        }
    }

    func open(_ bookmark: FavoriteBookmark) {
        guard let url = resolvedURL(for: bookmark) else {
            AppLog.warn("打不开收藏 \(bookmark.name)", category: "favorites")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ bookmark: FavoriteBookmark) {
        guard let url = resolvedURL(for: bookmark) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openDesktop() {
        NSWorkspace.shared.open(Self.desktopURL)
    }

    func openTrash() {
        NSWorkspace.shared.open(Self.trashURL)
    }

    func emptyTrash() {
        let trash = Self.trashURL
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            promptFullDiskAccessOnce()
            openTrash()
            return
        }

        if let script = NSAppleScript(source: "tell application \"Finder\" to empty the trash") {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil {
                refreshTrashState()
                return
            }
        }

        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
        refreshTrashState()
    }

    func refreshTrashState() {
        let trash = Self.trashURL
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: [.isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            if isTrashFull { isTrashFull = false }
            return
        }
        let full = items.contains { !$0.lastPathComponent.hasPrefix(".") }
        if full != isTrashFull {
            isTrashFull = full
        }
    }

    func icon(for bookmark: FavoriteBookmark) -> NSImage {
        if let url = resolvedURL(for: bookmark) {
            return AppIconCache.icon(forFile: url.path, size: 64)
        }
        return NSImage(systemSymbolName: bookmark.isFolder ? "folder.fill" : "doc", accessibilityDescription: bookmark.name)
            ?? NSImage()
    }

    func desktopIcon() -> NSImage {
        AppIconCache.icon(forFile: Self.desktopURL.path, size: 64)
    }

    func trashIcon() -> NSImage {
        let name = isTrashFull ? NSImage.trashFullName : NSImage.trashEmptyName
        if let image = NSImage(named: name) { return image }
        return NSImage(systemSymbolName: "trash", accessibilityDescription: "废纸篓") ?? NSImage()
    }

    private func contains(url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        return bookmarks.contains { bookmark in
            resolvedURL(for: bookmark)?.standardizedFileURL.path == standardized
        }
    }

    private func promptFullDiskAccessOnce() {
        guard !didPromptFDA else { return }
        didPromptFDA = true
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([FavoriteBookmark].self, from: data)
        else {
            bookmarks = []
            return
        }
        bookmarks = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
