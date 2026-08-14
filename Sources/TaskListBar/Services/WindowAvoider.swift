import AppKit
import ApplicationServices
import Foundation

/// Lifts zoomed / maximized windows so they sit above the taskbar instead of
/// drawing underneath it. Requires Accessibility permission.
@MainActor
final class WindowAvoider {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var debounce: Task<Void, Never>?
    private static let promptedKey = "didPromptAccessibilityAccess"
    private var didPrompt = UserDefaults.standard.bool(forKey: WindowAvoider.promptedKey)
    private var enabled = true

    func start() {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.schedule(delay: 0.2, frontmostOnly: true)
                }
            }
        )
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.schedule(delay: 0.25)
                }
            }
        )
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.schedule(delay: 0.28)
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
                    self?.schedule(delay: 0.2)
                }
            }
        )
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard Self.mouseIsNearTaskbar() else { return }
            Task { @MainActor in
                self?.schedule(delay: 0.4, frontmostOnly: true)
            }
        }
        schedule(delay: 0.5)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for token in observers {
            workspace.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            schedule(delay: 0.05)
        }
    }

    func requestAccess() {
        markPrompted()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !AXIsProcessTrusted() {
            Self.openAccessibilitySettings()
        }
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    private static func mouseIsNearTaskbar() -> Bool {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        guard let screen else { return false }
        return location.y <= screen.frame.minY + TaskbarMetrics.barHeight + 48
    }

    static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func schedule(delay: TimeInterval, frontmostOnly: Bool = false) {
        guard enabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            let nanos = UInt64(max(delay, 0.04) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.adjust(frontmostOnly: frontmostOnly)
            }
        }
    }

    private func adjust(frontmostOnly: Bool) {
        guard enabled else { return }
        guard AXIsProcessTrusted() else {
            promptOnceIfNeeded()
            return
        }

        let apps: [NSRunningApplication]
        if frontmostOnly {
            apps = [NSWorkspace.shared.frontmostApplication].compactMap { $0 }
        } else {
            apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        }

        for app in apps {
            guard app.processIdentifier != ownPID else { continue }
            insetWindows(of: app)
        }
    }

    private func promptOnceIfNeeded() {
        guard !didPrompt else { return }
        markPrompted()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func markPrompted() {
        didPrompt = true
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
    }

    private func insetWindows(of app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return }

        for window in windows {
            inset(window)
        }
    }

    private func inset(_ window: AXUIElement) {
        guard copyString(window, kAXRoleAttribute as CFString) == (kAXWindowRole as String) else { return }
        if copyString(window, kAXSubroleAttribute as CFString) == (kAXDialogSubrole as String) { return }
        if copyBool(window, kAXMinimizedAttribute as CFString) == true { return }
        if copyBool(window, "AXFullScreen" as CFString) == true { return }

        guard let axPosition = copyPoint(window, kAXPositionAttribute as CFString),
              var axSize = copySize(window, kAXSizeAttribute as CFString)
        else { return }

        let cocoa = cocoaFrame(axPosition: axPosition, axSize: axSize)
        guard let screen = screenContaining(cocoa) else { return }

        if isFullscreen(cocoa, on: screen) { return }

        // Tuck a few points under the bar so the other app's bottom-edge
        // resize handle is covered and cannot sit on the taskbar.
        let cover: CGFloat = 8
        let desiredMinY = screen.frame.minY + TaskbarMetrics.barHeight - cover
        let overlap = desiredMinY - cocoa.minY
        guard overlap > 4 else { return }

        let touchesBottom = cocoa.minY <= screen.frame.minY + 10
        let isTall = cocoa.height >= min(420, screen.visibleFrame.height * 0.55)
        guard touchesBottom, isTall else { return }
        guard axSize.height - overlap > 120 else { return }

        axSize.height -= overlap
        setSize(window, axSize)
    }

    private func isFullscreen(_ frame: CGRect, on screen: NSScreen) -> Bool {
        abs(frame.minX - screen.frame.minX) < 4
            && abs(frame.width - screen.frame.width) < 4
            && abs(frame.height - screen.frame.height) < 4
    }

    private func screenContaining(_ frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private func cocoaFrame(axPosition: CGPoint, axSize: CGSize) -> CGRect {
        let top = primaryMaxY()
        return CGRect(
            x: axPosition.x,
            y: top - axPosition.y - axSize.height,
            width: axSize.width,
            height: axSize.height
        )
    }

    private func primaryMaxY() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }

    private func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private func copyBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? Bool
    }

    private func copyPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func copySize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}
