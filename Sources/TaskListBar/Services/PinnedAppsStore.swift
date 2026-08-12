import AppKit
import Combine
import Foundation

@MainActor
final class PinnedAppsStore: ObservableObject {
    private let defaultsKey = "pinnedBundleIdentifiers"

    @Published private(set) var pinnedBundleIDs: [String] = []

    init() {
        load()
        if pinnedBundleIDs.isEmpty {
            pinnedBundleIDs = defaultPins()
            save()
        }
    }

    func isPinned(_ bundleIdentifier: String) -> Bool {
        pinnedBundleIDs.contains(bundleIdentifier)
    }

    func pin(_ bundleIdentifier: String) {
        guard !pinnedBundleIDs.contains(bundleIdentifier) else { return }
        pinnedBundleIDs.append(bundleIdentifier)
        save()
    }

    func unpin(_ bundleIdentifier: String) {
        pinnedBundleIDs.removeAll { $0 == bundleIdentifier }
        save()
    }

    func toggle(_ bundleIdentifier: String) {
        if isPinned(bundleIdentifier) {
            unpin(bundleIdentifier)
        } else {
            pin(bundleIdentifier)
        }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        pinnedBundleIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func reorder(draggedID: String, targetID: String) {
        guard let from = pinnedBundleIDs.firstIndex(of: draggedID),
              let to = pinnedBundleIDs.firstIndex(of: targetID),
              from != to else { return }
        pinnedBundleIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    private func load() {
        pinnedBundleIDs = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    private func save() {
        UserDefaults.standard.set(pinnedBundleIDs, forKey: defaultsKey)
    }

    private func defaultPins() -> [String] {
        [
            "com.apple.finder",
            "com.apple.Safari",
            "com.apple.Terminal"
        ].filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}
