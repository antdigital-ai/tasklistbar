import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class SpacesMonitor: ObservableObject {
    @Published private(set) var currentSpace: Int = 1
    @Published private(set) var spaceCount: Int = 1
    @Published private(set) var isFullscreenSpace = false
    var onFullscreenDetected: (() -> Void)?
    var onActiveSpaceChanged: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private static var axFullscreenCache: (value: Bool, at: Date)?
    private static let axFullscreenTTL: TimeInterval = 1.2

    func start() {
        refresh()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    AppLog.info("event=spaceChange", category: "fullscreen")
                    self.probeAndApplyFullscreen(reason: "spaceChange")
                    self.onActiveSpaceChanged?()
                    self.scheduleRefresh()
                }
            }
        )
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.probeAndApplyFullscreen(reason: "appActivate")
                }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.probeAndApplyFullscreen(reason: "screenParams")
                    self.refresh(updateFullscreen: false)
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
        refresh(updateFullscreen: false)
        debounceTask = Task { [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.probeAndApplyFullscreen(reason: "poll") }
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh() }
        }
    }

    func probeAndApplyFullscreen(reason: String = "probe") {
        guard looksFullscreenNow(), !isFullscreenSpace else { return }
        AppLog.info("hide now reason=\(reason) \(snapshot())", category: "fullscreen")
        isFullscreenSpace = true
        onFullscreenDetected?()
    }

    func looksFullscreenNow() -> Bool {
        if NSApp.currentSystemPresentationOptions.contains(.fullScreen) { return true }
        if SpaceAPI.isAvailable {
            return SpaceAPI.readSpaces(displayUUID: Self.displayUUID(for: NSScreen.main))?.isFullscreen == true
        }
        return Self.isAXFullscreen()
    }

    func refresh(updateFullscreen: Bool = true) {
        guard let info = SpaceAPI.readSpaces(displayUUID: Self.displayUUID(for: NSScreen.main)) else { return }
        let nextCurrent = info.current
        let nextCount = max(info.count, 1)
        if nextCurrent != currentSpace {
            currentSpace = nextCurrent
        }
        if nextCount != spaceCount {
            spaceCount = nextCount
        }
        if updateFullscreen {
            let next = info.isFullscreen
                || NSApp.currentSystemPresentationOptions.contains(.fullScreen)
                || (!SpaceAPI.isAvailable && Self.isAXFullscreen())
            if next != isFullscreenSpace {
                AppLog.info(
                    "set isFullscreenSpace \(isFullscreenSpace) -> \(next) sky=\(info.isFullscreen) type=\(info.type) \(snapshot())",
                    category: "fullscreen"
                )
                isFullscreenSpace = next
            }
        }
    }

    private func snapshot() -> String {
        let info = SpaceAPI.readSpaces(displayUUID: Self.displayUUID(for: NSScreen.main))
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        return "sky=\(info?.isFullscreen ?? false) type=\(info?.type ?? -1) front=\(front) space=\(currentSpace)/\(spaceCount)"
    }

    private static func isAXFullscreen() -> Bool {
        if let cached = axFullscreenCache, Date().timeIntervalSince(cached.at) < axFullscreenTTL {
            return cached.value
        }
        let value = readAXFullscreen()
        axFullscreenCache = (value, Date())
        return value
    }

    private static func readAXFullscreen() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.04)
        for attribute in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success, let ref else { continue }
            let window = ref as! AXUIElement
            if AXHelper.bool(window, "AXFullScreen" as CFString) == true { return true }
        }
        return false
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

    /// Toggle "Show Desktop" by tapping F11 (macOS default), the cleanest
    /// system-level way to minimize all windows onto the desktop edge.
    func toggleShowDesktop() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x67), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0x67), keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        AppLog.info("显示桌面", category: "spaces")
    }
}

/// Cache SkyLight symbols once — avoid dlopen/dlclose on every refresh.
private enum SpaceAPI {
    static var isAvailable: Bool { symbols != nil }
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

    nonisolated static func readSpaces(displayUUID: String?) -> (current: Int, count: Int, isFullscreen: Bool, type: Int, matchedInList: Bool)? {
        guard let symbols else { return (1, 1, false, 0, false) }
        let connection = symbols.main()
        guard let unmanaged = symbols.copy(connection) else { return (1, 1, false, 0, false) }
        let displays = unmanaged.takeRetainedValue() as NSArray

        guard let display = pickDisplay(displays, uuid: displayUUID),
              let spaces = display["Spaces"] as? [NSDictionary],
              !spaces.isEmpty
        else {
            return (1, 1, false, 0, false)
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
        var matchedInList = false
        for (offset, space) in spaces.enumerated() {
            let sid = space["ManagedSpaceID"] ?? space["id64"]
            if let currentID, isEqualSpaceID(sid, currentID) {
                index = offset + 1
                matchedInList = true
                if let type = space["type"] as? Int {
                    matchedType = type
                }
                break
            }
        }

        let type = matchedType ?? -1
        return (index, spaces.count, type == fullscreenSpaceType, type, matchedInList)
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
