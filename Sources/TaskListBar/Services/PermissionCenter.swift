import AppKit
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Foundation

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording
    case automation
    case calendar
    case location
    case bluetooth
    case fullDisk

    var id: String { rawValue }

    var isRequired: Bool { self == .accessibility }

    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .automation: return "控制 Finder"
        case .calendar: return "日历"
        case .location: return "位置"
        case .bluetooth: return "蓝牙"
        case .fullDisk: return "完全磁盘访问"
        }
    }

    var reason: String {
        switch self {
        case .accessibility: return "最大化让出底栏、切换窗口、读取角标"
        case .screenRecording: return "显示其他窗口的标题，不会录像"
        case .automation: return "一键清倒废纸篓"
        case .calendar: return "在预览里显示日程"
        case .location: return "日历中显示本周天气"
        case .bluetooth: return "托盘显示连接状态并开关蓝牙"
        case .fullDisk: return "准确显示废纸篓是否有文件"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "hand.raised.fill"
        case .screenRecording: return "rectangle.dashed"
        case .automation: return "trash.fill"
        case .calendar: return "calendar"
        case .location: return "location.fill"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .fullDisk: return "internaldrive.fill"
        }
    }

    var settingsURLs: [String] {
        switch self {
        case .accessibility:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ]
        case .screenRecording:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ]
        case .automation:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            ]
        case .calendar:
            return [
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Calendars",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            ]
        case .location:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
            ]
        case .bluetooth:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
            ]
        case .fullDisk:
            return [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            ]
        }
    }
}

enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
}

struct PermissionItem: Identifiable, Equatable {
    let kind: PermissionKind
    var state: PermissionState

    var id: String { kind.id }
    var isGranted: Bool { state == .granted }
}

@MainActor
final class PermissionCenter: NSObject, ObservableObject {
    @Published private(set) var items: [PermissionItem] = PermissionKind.allCases.map {
        PermissionItem(kind: $0, state: .notDetermined)
    }

    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var locationManager: CLLocationManager?
    private var bluetoothProbe: BluetoothProbe?
    private var didStart = false

    var requiredItems: [PermissionItem] { items.filter(\.kind.isRequired) }
    var optionalItems: [PermissionItem] { items.filter { !$0.kind.isRequired } }
    var missingRequiredCount: Int { requiredItems.filter { !$0.isGranted }.count }
    var missingCount: Int { items.filter { !$0.isGranted }.count }
    var hasRequired: Bool { missingRequiredCount == 0 }
    var missingRequiredTitle: String {
        requiredItems.first { !$0.isGranted }?.kind.title ?? ""
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        refresh()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        didStart = false
    }

    func setPageVisible(_ visible: Bool) {
        if visible {
            refresh()
            startPolling()
        } else {
            stopPolling()
        }
    }

    func refresh() {
        let next = PermissionKind.allCases.map { PermissionItem(kind: $0, state: Self.state(for: $0)) }
        if next != items {
            items = next
        }
    }

    func open(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Self.openSettings(kind.settingsURLs)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            Self.openSettings(kind.settingsURLs)
        case .automation:
            _ = Self.finderAutomationState(prompt: true)
            if Self.finderAutomationState(prompt: false) != .granted {
                Self.openSettings(kind.settingsURLs)
            }
        case .calendar:
            requestCalendar()
        case .location:
            requestLocation()
        case .bluetooth:
            requestBluetooth()
        case .fullDisk:
            Self.openSettings(kind.settingsURLs)
        }
        scheduleRefresh()
    }

    private func requestCalendar() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                }
            } else {
                store.requestAccess(to: .event) { [weak self] _, _ in
                    Task { @MainActor in self?.refresh() }
                }
            }
        } else {
            Self.openSettings(PermissionKind.calendar.settingsURLs)
        }
    }

    private func requestLocation() {
        let manager = locationManager ?? CLLocationManager()
        locationManager = manager
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            Self.openSettings(PermissionKind.location.settingsURLs)
        }
    }

    private func requestBluetooth() {
        if #available(macOS 10.15, *) {
            switch CBManager.authorization {
            case .notDetermined:
                let probe = BluetoothProbe()
                probe.onChange = { [weak self] in
                    Task { @MainActor in self?.refresh() }
                }
                probe.start()
                bluetoothProbe = probe
            default:
                Self.openSettings(PermissionKind.bluetooth.settingsURLs)
            }
        } else {
            Self.openSettings(PermissionKind.bluetooth.settingsURLs)
        }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refresh() }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { self?.refresh() }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { self?.refresh() }
        }
    }

    private static func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .automation:
            return finderAutomationState(prompt: false)
        case .calendar:
            return calendarState()
        case .location:
            return locationState()
        case .bluetooth:
            return bluetoothState()
        case .fullDisk:
            return hasFullDiskAccess() ? .granted : .notDetermined
        }
    }

    private static func calendarState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    private static func locationState() -> PermissionState {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    private static func bluetoothState() -> PermissionState {
        if #available(macOS 10.15, *) {
            switch CBManager.authorization {
            case .allowedAlways:
                return .granted
            case .notDetermined:
                return .notDetermined
            default:
                return .denied
            }
        }
        return .granted
    }

    private static func finderAutomationState(prompt: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let aeDesc = target.aeDesc else { return .notDetermined }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, prompt)
        switch Int(status) {
        case 0:
            return .granted
        case -1744:
            return .notDetermined
        default:
            return .denied
        }
    }

    private static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        ]
        return probes.contains { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    static func openSettings(_ urls: [String]) {
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}

private final class BluetoothProbe: NSObject, CBCentralManagerDelegate {
    var onChange: (() -> Void)?
    private var manager: CBCentralManager?

    func start() {
        manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onChange?()
    }
}
