import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class SpacesMonitor: ObservableObject {
    @Published private(set) var currentSpace: Int = 1
    @Published private(set) var spaceCount: Int = 1
    @Published private(set) var isFullscreenSpace = false

    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?

    func start() {
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh()
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh()
                }
            }
        )
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspace.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        refresh()
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
        guard let info = SpaceAPI.readSpaces(displayUUID: Self.displayUUID(for: NSScreen.main)) else { return }
        let nextCurrent = info.current
        let nextCount = max(info.count, 1)
        if nextCurrent != currentSpace {
            currentSpace = nextCurrent
        }
        if nextCount != spaceCount {
            spaceCount = nextCount
        }
        if info.isFullscreen != isFullscreenSpace {
            isFullscreenSpace = info.isFullscreen
        }
    }

    private static func displayUUID(for screen: NSScreen?) -> String? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(truncating: number)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
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

    /// SkyLight space types: 0 user desktop, 2 system (Mission Control), 4 fullscreen.
    private static let fullscreenSpaceType = 4

    nonisolated static func readSpaces(displayUUID: String?) -> (current: Int, count: Int, isFullscreen: Bool)? {
        guard let symbols else { return (1, 1, false) }
        let connection = symbols.main()
        guard let unmanaged = symbols.copy(connection) else { return (1, 1, false) }
        let displays = unmanaged.takeRetainedValue() as NSArray

        guard let display = pickDisplay(displays, uuid: displayUUID),
              let spaces = display["Spaces"] as? [NSDictionary],
              !spaces.isEmpty
        else {
            return (1, 1, false)
        }

        let currentSpace = display["Current Space"] as? NSDictionary
        let currentID: Any? = {
            if let currentSpace {
                return currentSpace["ManagedSpaceID"] ?? currentSpace["id64"]
            }
            return display["Current Space"]
        }()
        let currentType = currentSpace?["type"] as? Int

        var index = 1
        var matchedType = currentType
        for (offset, space) in spaces.enumerated() {
            let sid = space["ManagedSpaceID"] ?? space["id64"]
            if let currentID, isEqualSpaceID(sid, currentID) {
                index = offset + 1
                if let type = space["type"] as? Int {
                    matchedType = type
                }
                break
            }
        }

        return (index, spaces.count, matchedType == fullscreenSpaceType)
    }

    nonisolated private static func pickDisplay(_ displays: NSArray, uuid: String?) -> NSDictionary? {
        if let uuid {
            for item in displays {
                guard let dict = item as? NSDictionary,
                      let identifier = dict["Display Identifier"] as? String
                else { continue }
                if identifier.caseInsensitiveCompare(uuid) == .orderedSame {
                    return dict
                }
            }
        }
        return displays.firstObject as? NSDictionary
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
