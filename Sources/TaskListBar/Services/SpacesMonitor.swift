import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class SpacesMonitor: ObservableObject {
    @Published private(set) var currentSpace: Int = 1
    @Published private(set) var spaceCount: Int = 1

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?

    func start() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // SkyLight sometimes reports the previous space immediately after the notification.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh() }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh() }
        }
    }

    func refresh() {
        guard let info = SpaceAPI.readSpaces() else { return }
        let nextCurrent = info.current
        let nextCount = max(info.count, 1)
        if nextCurrent != currentSpace {
            currentSpace = nextCurrent
        }
        if nextCount != spaceCount {
            spaceCount = nextCount
        }
    }

    func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Mission Control"]
        try? task.run()
    }
}

/// Cache SkyLight symbols once — avoid dlopen/dlclose on every refresh.
private enum SpaceAPI {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let symbols: (main: MainConnectionID, copy: CopyManagedDisplaySpaces)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let mainSym = dlsym(handle, "CGSMainConnectionID"),
              let copySym = dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else {
            return nil
        }
        return (
            unsafeBitCast(mainSym, to: MainConnectionID.self),
            unsafeBitCast(copySym, to: CopyManagedDisplaySpaces.self)
        )
    }()

    nonisolated static func readSpaces() -> (current: Int, count: Int)? {
        guard let symbols else { return (1, 1) }
        let connection = symbols.main()
        guard let unmanaged = symbols.copy(connection) else { return (1, 1) }
        let displays = unmanaged.takeRetainedValue() as NSArray

        guard let first = displays.firstObject as? NSDictionary,
              let spaces = first["Spaces"] as? [NSDictionary],
              !spaces.isEmpty
        else {
            return (1, 1)
        }

        let currentID: Any? = {
            if let dict = first["Current Space"] as? NSDictionary {
                return dict["ManagedSpaceID"] ?? dict["id64"]
            }
            return first["Current Space"]
        }()

        var index = 1
        for (offset, space) in spaces.enumerated() {
            let sid = space["ManagedSpaceID"] ?? space["id64"]
            if let currentID, isEqualSpaceID(sid, currentID) {
                index = offset + 1
                break
            }
        }

        return (index, spaces.count)
    }

    nonisolated private static func isEqualSpaceID(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case let (l as NSNumber, r as NSNumber):
            return l == r
        case let (l as String, r as String):
            return l == r
        default:
            return "\(lhs ?? "")" == "\(rhs ?? "")"
        }
    }
}
