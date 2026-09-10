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
    private var retryTask: Task<Void, Never>?
    private static let promptedKey = "didPromptAccessibilityAccess"
    private var didPrompt = UserDefaults.standard.bool(forKey: WindowAvoider.promptedKey)
    private var enabled = true

    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var observedWindow: AXUIElement?
    private let callbackBox = CallbackBox()

    func start() {
        stop()
        callbackBox.onEvent = { [weak self] in
            Task { @MainActor in
                self?.schedule(delay: 0.16, frontmostOnly: true)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.attachFrontmostObserver()
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
                    self?.attachFrontmostObserver()
                    self?.schedule(delay: 0.25, frontmostOnly: true)
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
                    self?.attachFrontmostObserver()
                    self?.schedule(delay: 0.28, frontmostOnly: true)
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
            guard Self.mouseSuggestsWindowChange() else { return }
            Task { @MainActor in
                self?.schedule(delay: 0.28, frontmostOnly: true)
            }
        }
        attachFrontmostObserver()
        schedule(delay: 0.5)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        retryTask?.cancel()
        retryTask = nil
        detachObserver()
        callbackBox.onEvent = nil
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
        } else {
            detachObserver()
        }
    }

    func refresh() {
        schedule(delay: 0.08)
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

    /// Green-button / title-bar zoom is at the top; dragging the bottom edge
    /// onto the taskbar is at the bottom. Either should re-check inset.
    private static func mouseSuggestsWindowChange() -> Bool {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        guard let screen else { return false }
        let nearBar = location.y <= screen.frame.minY + TaskbarMetrics.barHeight + 48
        let nearTitle = location.y >= screen.frame.maxY - 56
        return nearBar || nearTitle
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
        guard AXIsProcessTrusted() else { return }
        attachFrontmostObserver()

        let apps: [NSRunningApplication]
        if frontmostOnly {
            apps = [NSWorkspace.shared.frontmostApplication].compactMap { $0 }
        } else {
            apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        }

        for app in apps {
            guard app.processIdentifier != ownPID else { continue }
            insetWindows(of: app, retry: true)
        }
    }

    private func markPrompted() {
        didPrompt = true
        UserDefaults.standard.set(true, forKey: Self.promptedKey)
    }

    private func insetWindows(of app: NSRunningApplication, retry: Bool) {
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.05)

        var windows: [AXUIElement] = []
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let listed = windowsRef as? [AXUIElement] {
            windows = listed
        }
        if windows.isEmpty {
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
               let focusedRef {
                windows = [focusedRef as! AXUIElement]
            }
        }
        guard !windows.isEmpty else { return }

        var didChange = false
        for window in windows {
            if inset(window) {
                didChange = true
            }
        }
        if didChange, retry {
            scheduleRetry(pid: pid)
        }
    }

    private func scheduleRetry(pid: pid_t) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.processIdentifier != 0
                else { return }
                self?.insetWindows(of: app, retry: false)
            }
        }
    }

    @discardableResult
    private func inset(_ window: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.04)
        guard copyString(window, kAXRoleAttribute as CFString) == (kAXWindowRole as String) else { return false }
        if copyString(window, kAXSubroleAttribute as CFString) == (kAXDialogSubrole as String) { return false }
        if copyBool(window, kAXMinimizedAttribute as CFString) == true { return false }
        // Native Space fullscreen stays untouched; the taskbar hides instead.
        if copyBool(window, "AXFullScreen" as CFString) == true { return false }

        guard let axPosition = copyPoint(window, kAXPositionAttribute as CFString),
              let axSize = copySize(window, kAXSizeAttribute as CFString)
        else { return false }

        let cocoa = cocoaFrame(axPosition: axPosition, axSize: axSize)
        guard let screen = screenContaining(cocoa) else { return false }

        // 2pt tuck hides the hairline without covering page content / chat input.
        let cover: CGFloat = 2
        let desiredMinY = screen.frame.minY + TaskbarMetrics.barHeight - cover
        let overlap = desiredMinY - cocoa.minY
        guard overlap > 4 else { return false }

        let isTall = cocoa.height >= min(420, screen.visibleFrame.height * 0.55)
        let fillsWidth = abs(cocoa.width - screen.frame.width) < 24
            || abs(cocoa.width - screen.visibleFrame.width) < 24
        let fillsHeight = cocoa.height >= screen.visibleFrame.height * 0.82
            || abs(cocoa.height - screen.frame.height) < 12
        let sitsOnBottom = cocoa.minY <= screen.frame.minY + 12
        let looksMaximized = (sitsOnBottom && isTall) || (fillsWidth && fillsHeight)
        guard looksMaximized else { return false }

        let newHeight = cocoa.maxY - desiredMinY
        guard newHeight > 120 else { return false }

        if copyBool(window, "AXZoomed" as CFString) == true {
            setBool(window, "AXZoomed" as CFString, false)
        }
        setPoint(window, axPosition)
        setSize(window, CGSize(width: axSize.width, height: newHeight))
        return true
    }

    private func attachFrontmostObserver() {
        guard enabled, AXIsProcessTrusted() else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownPID,
              app.activationPolicy == .regular
        else {
            detachObserver()
            return
        }

        let pid = app.processIdentifier
        if pid != observedPID || axObserver == nil {
            detachObserver()
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { _, _, _, refcon in
                guard let refcon else { return }
                Unmanaged<CallbackBox>.fromOpaque(refcon).takeUnretainedValue().ping()
            }, &observer)
            guard result == .success, let observer else { return }

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.05)
            let refcon = Unmanaged.passUnretained(callbackBox).toOpaque()
            _ = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
            _ = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            axObserver = observer
            observedPID = pid
        }
        attachFocusedWindowNotifications(for: pid)
    }

    private func attachFocusedWindowNotifications(for pid: pid_t) {
        guard let observer = axObserver else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef
        else { return }
        let window = focusedRef as! AXUIElement
        if let current = observedWindow, CFEqual(current, window) {
            return
        }
        if let current = observedWindow {
            AXObserverRemoveNotification(observer, current, kAXResizedNotification as CFString)
            AXObserverRemoveNotification(observer, current, kAXMovedNotification as CFString)
        }
        let refcon = Unmanaged.passUnretained(callbackBox).toOpaque()
        _ = AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, refcon)
        observedWindow = window
    }

    private func detachObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if observedPID != 0 {
                let app = AXUIElementCreateApplication(observedPID)
                AXObserverRemoveNotification(observer, app, kAXWindowCreatedNotification as CFString)
                AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
            }
            if let window = observedWindow {
                AXObserverRemoveNotification(observer, window, kAXResizedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXMovedNotification as CFString)
            }
        }
        axObserver = nil
        observedPID = 0
        observedWindow = nil
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

    private func setPoint(_ element: AXUIElement, _ point: CGPoint) {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) {
        var mutable = size
        guard let value = AXValueCreate(.cgSize, &mutable) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func setBool(_ element: AXUIElement, _ attribute: CFString, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute, value as CFBoolean)
    }
}

private final class CallbackBox: @unchecked Sendable {
    var onEvent: (() -> Void)?

    func ping() {
        onEvent?()
    }
}
