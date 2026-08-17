import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct PinnedItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case app
        case folder
    }

    let id: String
    var kind: Kind
    var bundleID: String?
    var name: String
    var bookmark: Data?

    var isFolder: Bool { kind == .folder }

    static func app(_ bundleIdentifier: String) -> PinnedItem {
        PinnedItem(id: bundleIdentifier, kind: .app, bundleID: bundleIdentifier, name: "", bookmark: nil)
    }

    static func folder(id: UUID = UUID(), name: String, bookmark: Data) -> PinnedItem {
        PinnedItem(id: "folder:\(id.uuidString)", kind: .folder, bundleID: nil, name: name, bookmark: bookmark)
    }
}

@MainActor
final class PinnedAppsStore: ObservableObject {
    private let itemsKey = "pinnedItems"
    private let legacyKey = "pinnedBundleIdentifiers"

    @Published private(set) var items: [PinnedItem] = []

    var pinnedBundleIDs: [String] {
        items.compactMap { $0.kind == .app ? ($0.bundleID ?? $0.id) : nil }
    }

    init() {
        load()
        if items.isEmpty {
            items = defaultPins().map { .app($0) }
            save()
        }
    }

    func isPinned(_ id: String) -> Bool {
        items.contains { $0.id == id || $0.bundleID == id }
    }

    func pin(_ bundleIdentifier: String, before targetID: String? = nil) {
        if let from = index(of: bundleIdentifier) {
            if let targetID {
                move(id: items[from].id, before: targetID)
            }
            return
        }
        insert(.app(bundleIdentifier), before: targetID)
    }

    func unpin(_ id: String) {
        items.removeAll { $0.id == id || $0.bundleID == id }
        save()
    }

    func toggle(_ bundleIdentifier: String) {
        if isPinned(bundleIdentifier) {
            unpin(bundleIdentifier)
        } else {
            pin(bundleIdentifier)
        }
    }

    @discardableResult
    func pinFolder(url: URL, before targetID: String? = nil) -> Bool {
        if url.pathExtension.lowercased() == "app" {
            if let bid = Bundle(url: url)?.bundleIdentifier {
                pin(bid, before: targetID)
                return true
            }
            return false
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue || url.hasDirectoryPath else { return false }
        if let existing = existingFolder(for: url) {
            if let targetID {
                move(id: existing.id, before: targetID)
            }
            return true
        }

        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            insert(.folder(name: url.lastPathComponent, bookmark: data), before: targetID)
            return true
        } catch {
            AppLog.warn("固定文件夹失败 \(url.lastPathComponent): \(error.localizedDescription)", category: "pins")
            return false
        }
    }

    func item(id: String) -> PinnedItem? {
        items.first { $0.id == id }
    }

    func resolvedURL(for item: PinnedItem) -> URL? {
        guard let bookmark = item.bookmark else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
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

    func openFolder(_ item: PinnedItem) {
        guard let url = resolvedURL(for: item) else {
            AppLog.warn("打不开固定文件夹 \(item.name)", category: "pins")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealFolder(_ item: PinnedItem) {
        guard let url = resolvedURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func reorder(draggedID: String, targetID: String) {
        move(id: draggedID, before: targetID)
    }

    func moveToEnd(_ id: String) {
        guard let from = index(of: id), from != items.count - 1 else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: items.count)
        save()
    }

    private func insert(_ item: PinnedItem, before targetID: String?) {
        if let targetID, let to = index(of: targetID) {
            items.insert(item, at: to)
        } else {
            items.append(item)
        }
        save()
    }

    private func move(id: String, before targetID: String) {
        guard let from = index(of: id),
              let to = index(of: targetID),
              from != to
        else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    private func index(of id: String) -> Int? {
        items.firstIndex { $0.id == id || $0.bundleID == id }
    }

    private func existingFolder(for url: URL) -> PinnedItem? {
        let path = url.standardizedFileURL.path
        return items.first { pin in
            guard pin.isFolder else { return false }
            return resolvedURL(for: pin)?.standardizedFileURL.path == path
        }
    }

    private func containsFolder(_ url: URL) -> Bool {
        existingFolder(for: url) != nil
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: itemsKey),
           let decoded = try? JSONDecoder().decode([PinnedItem].self, from: data) {
            items = decoded
            return
        }
        let legacy = UserDefaults.standard.stringArray(forKey: legacyKey) ?? []
        items = legacy.map { .app($0) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: itemsKey)
        }
        UserDefaults.standard.set(pinnedBundleIDs, forKey: legacyKey)
    }

    private func defaultPins() -> [String] {
        [
            "com.apple.finder",
            "com.apple.Safari",
            "com.apple.Terminal"
        ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}

enum DroppedFileURLs {
    static func load(_ providers: [NSItemProvider], onMain: @escaping @MainActor (URL) -> Void) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
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
                    onMain(url)
                }
            }
        }
        return accepted
    }
}
