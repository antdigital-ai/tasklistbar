import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class TrashMonitor: ObservableObject {
    @Published private(set) var itemCount: Int = 0
    @Published private(set) var isEmpty: Bool = true

    private var folderSource: DispatchSourceFileSystemObject?
    private var folderFD: CInt = -1
    private var debounceTask: Task<Void, Never>?
    private var refreshGeneration = 0

    var trashURL: URL {
        if let url = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true)
    }

    func start() {
        scheduleRefresh(delayNanoseconds: 0)
        watchTrashFolder()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        folderSource?.cancel()
        folderSource = nil
        if folderFD >= 0 {
            close(folderFD)
            folderFD = -1
        }
    }

    func refresh() {
        scheduleRefresh(delayNanoseconds: 0)
    }

    private func scheduleRefresh(delayNanoseconds: UInt64) {
        debounceTask?.cancel()
        let generation = refreshGeneration + 1
        refreshGeneration = generation
        let url = trashURL

        debounceTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let count = await Task.detached(priority: .utility) {
                Self.countVisibleItems(at: url)
            }.value
            guard let self, self.refreshGeneration == generation else { return }
            if self.itemCount != count {
                self.itemCount = count
            }
            let empty = count == 0
            if self.isEmpty != empty {
                self.isEmpty = empty
            }
        }
    }

    nonisolated private static func countVisibleItems(at url: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }
        return contents.reduce(into: 0) { partial, item in
            if !item.lastPathComponent.hasPrefix(".") {
                partial += 1
            }
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(trashURL)
    }

    func emptyTrash() {
        let script = """
        tell application "Finder"
            if (count of items in trash) > 0 then
                empty the trash
            end if
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
        scheduleRefresh(delayNanoseconds: 400_000_000)
    }

    private func watchTrashFolder() {
        let path = trashURL.path
        folderFD = open(path, O_EVTONLY)
        guard folderFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderFD,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh(delayNanoseconds: 250_000_000)
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.folderFD >= 0 {
                close(self.folderFD)
                self.folderFD = -1
            }
        }
        folderSource = source
        source.resume()
    }
}
