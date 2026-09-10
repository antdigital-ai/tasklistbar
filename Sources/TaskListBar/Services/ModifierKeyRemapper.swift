import AppKit
import Combine
import Foundation
import IOKit.hid

/// Persists and applies modifier-key remapping per physical keyboard.
@MainActor
final class ModifierKeyRemapper: ObservableObject {
    private static let hidUsagePageBase: UInt64 = 0x7000_0000_0
    private static let storeKey = "modifierKeyConfigurationByKeyboard"
    private static let legacyKey = "modifierKeyConfiguration"

    @Published private(set) var keyboards: [KeyboardDevice] = []
    @Published private(set) var selectedKeyboardID = ""
    @Published private(set) var configuration: ModifierKeyConfiguration = .default
    @Published private(set) var lastError: String?

    private var store = Store()
    private var wakeObserver: NSObjectProtocol?
    private var hidManager: IOHIDManager?
    private var applyTask: Task<Void, Never>?
    private var didClearGlobal = false

    private struct Store: Codable {
        var configurations: [String: ModifierKeyConfiguration] = [:]
        var selectedID: String?
        var names: [String: String] = [:]
    }

    init() {
        loadStore()
        startWatchingKeyboards()
        refreshKeyboards(apply: false)
        applyAllConnected()
        observeWake()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let hidManager {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func selectKeyboard(_ id: String) {
        guard keyboards.contains(where: { $0.id == id }) else { return }
        selectedKeyboardID = id
        configuration = store.configurations[id] ?? .default
        store.selectedID = id
        persistStore()
    }

    func setTarget(_ target: ModifierKeyTarget, for role: ModifierKeyRole) {
        var next = configuration
        next.setTarget(target, for: role)
        updateSelected(next)
    }

    func applyWindowsKeyboardPreset() {
        updateSelected(.windowsKeyboard)
    }

    func resetToDefault() {
        updateSelected(.default)
    }

    func prepareForDisplay() {
        refreshKeyboards(apply: false)
    }

    func reapply() {
        refreshKeyboards(apply: true)
    }

    private func updateSelected(_ next: ModifierKeyConfiguration) {
        configuration = next
        let id = selectedKeyboardID
        store.configurations[id] = next
        persistStore()
        if let keyboard = keyboards.first(where: { $0.id == id }), keyboard.isConnected {
            apply(next, to: keyboard)
        }
    }

    private func loadStore() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store = decoded
        }

        if let data = UserDefaults.standard.data(forKey: Self.legacyKey),
           let legacy = try? JSONDecoder().decode(ModifierKeyConfiguration.self, from: data) {
            if store.configurations.isEmpty {
                store.configurations["builtin"] = legacy
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
            persistStore()
        }
    }

    private func persistStore() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    private func refreshKeyboards(apply: Bool) {
        var devices = devicesFromHID()
        if devices.isEmpty {
            devices = Self.scanKeyboards()
        }
        let connectedIDs = Set(devices.map(\.id))

        for (id, name) in store.names where !connectedIDs.contains(id) {
            devices.append(
                KeyboardDevice(
                    id: id,
                    name: name,
                    vendorID: 0,
                    productID: 0,
                    isBuiltIn: id == "builtin",
                    isConnected: false
                )
            )
        }

        if devices.isEmpty {
            devices = [
                KeyboardDevice(id: "builtin", name: "内置键盘", vendorID: 0, productID: 0, isBuiltIn: true, isConnected: true)
            ]
        }

        devices.sort {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn && !$1.isBuiltIn }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        for device in devices where device.isConnected {
            store.names[device.id] = device.name
        }

        let previousIDs = Set(keyboards.map(\.id))
        let newlyConnected = devices.filter { $0.isConnected && !previousIDs.contains($0.id) && !keyboards.isEmpty }

        keyboards = devices

        let preferred = newlyConnected.last?.id
            ?? store.selectedID.flatMap { id in devices.contains(where: { $0.id == id }) ? id : nil }
            ?? devices.first(where: \.isConnected)?.id
            ?? devices.first?.id
            ?? "builtin"

        selectedKeyboardID = preferred
        store.selectedID = preferred
        configuration = store.configurations[preferred] ?? .default
        persistStore()

        if apply {
            applyAllConnected()
        } else if !newlyConnected.isEmpty {
            applyKeyboards(newlyConnected)
        }
    }

    private func applyAllConnected() {
        if !didClearGlobal {
            clearGlobalMapping()
            didClearGlobal = true
        }
        applyKeyboards(keyboards.filter(\.isConnected))
    }

    private func applyKeyboards(_ devices: [KeyboardDevice]) {
        var firstError: String?
        for keyboard in devices {
            let config = store.configurations[keyboard.id] ?? .default
            guard !config.isIdentity else { continue }
            do {
                try setUserKeyMapping(buildUserKeyMapping(from: config), matching: keyboard)
            } catch {
                firstError = firstError ?? error.localizedDescription
            }
        }
        lastError = firstError
    }

    private func apply(_ config: ModifierKeyConfiguration, to keyboard: KeyboardDevice) {
        if !config.isIdentity {
            clearSystemModifierMappings()
        }
        do {
            try setUserKeyMapping(buildUserKeyMapping(from: config), matching: keyboard)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func buildUserKeyMapping(from config: ModifierKeyConfiguration) -> [[String: UInt64]] {
        var result: [[String: UInt64]] = []

        for role in ModifierKeyRole.allCases {
            let target = config.target(for: role)
            for sourceUsage in role.hidUsages {
                let src = Self.hidUsagePageBase | sourceUsage
                if let destUsage = target.destinationUsage(forSourceUsage: sourceUsage) {
                    let dst = Self.hidUsagePageBase | destUsage
                    if src != dst {
                        result.append([
                            "HIDKeyboardModifierMappingSrc": src,
                            "HIDKeyboardModifierMappingDst": dst
                        ])
                    }
                } else {
                    result.append([
                        "HIDKeyboardModifierMappingSrc": src,
                        "HIDKeyboardModifierMappingDst": Self.hidUsagePageBase
                    ])
                }
            }
        }

        return result
    }

    private func setUserKeyMapping(_ mappings: [[String: UInt64]], matching keyboard: KeyboardDevice?) throws {
        let payload: [String: Any] = ["UserKeyMapping": mappings]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw RemapperError.encodingFailed
        }

        var arguments = ["property"]
        if let keyboard {
            arguments += ["--matching", keyboard.hidutilMatching]
        }
        arguments += ["--set", json]
        try Self.runHidutil(arguments)
    }

    private func clearGlobalMapping() {
        try? setUserKeyMapping([], matching: nil)
    }

    /// Remove System Settings modifier mappings so they don't stack with hidutil.
    private func clearSystemModifierMappings() {
        let prefix = "com.apple.keyboard.modifiermapping."
        let appID = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        let hostDomain = kCFPreferencesCurrentHost

        if let keys = CFPreferencesCopyKeyList(appID, user, hostDomain) as? [String] {
            for key in keys where key.hasPrefix(prefix) {
                CFPreferencesSetValue(key as CFString, nil, appID, user, hostDomain)
            }
        }
        for keyboard in keyboards where keyboard.isConnected {
            CFPreferencesSetValue("\(prefix)\(keyboard.preferenceID)" as CFString, nil, appID, user, hostDomain)
        }
        CFPreferencesSynchronize(appID, user, hostDomain)
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reapply()
            }
        }
    }

    private func startWatchingKeyboards() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let remapper = Unmanaged<ModifierKeyRemapper>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                remapper.scheduleRefresh()
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let remapper = Unmanaged<ModifierKeyRemapper>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                remapper.scheduleRefresh()
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
    }

    private func scheduleRefresh() {
        applyTask?.cancel()
        applyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            refreshKeyboards(apply: false)
        }
    }

    private func devicesFromHID() -> [KeyboardDevice] {
        guard let hidManager, let raw = IOHIDManagerCopyDevices(hidManager) else { return [] }
        var devices: [KeyboardDevice] = []
        var seen = Set<String>()
        for case let device as IOHIDDevice in (raw as NSSet) {
            let usagePage = hidNumber(device, kIOHIDPrimaryUsagePageKey) ?? hidNumber(device, kIOHIDDeviceUsagePageKey)
            let usage = hidNumber(device, kIOHIDPrimaryUsageKey) ?? hidNumber(device, kIOHIDDeviceUsageKey)
            if let usagePage, let usage, usagePage != UInt64(kHIDPage_GenericDesktop) || usage != UInt64(kHIDUsage_GD_Keyboard) {
                continue
            }
            let vendor = hidNumber(device, kIOHIDVendorIDKey) ?? 0
            let product = hidNumber(device, kIOHIDProductIDKey) ?? 0
            let name = hidString(device, kIOHIDProductKey)
            let transport = hidString(device, kIOHIDTransportKey)
            let builtIn = transport == "FIFO" || name.localizedCaseInsensitiveContains("Internal Keyboard")
            let id: String
            if builtIn && vendor == 0 && product == 0 {
                id = "builtin"
            } else if vendor == 0 && product == 0 {
                id = "name:\(name)"
            } else {
                id = "\(vendor)-\(product)"
            }
            guard seen.insert(id).inserted else { continue }
            devices.append(
                KeyboardDevice(
                    id: id,
                    name: name,
                    vendorID: vendor,
                    productID: product,
                    isBuiltIn: builtIn,
                    isConnected: true
                )
            )
        }
        return devices
    }

    private func hidNumber(_ device: IOHIDDevice, _ key: String) -> UInt64? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (value as? NSNumber)?.uint64Value
    }

    private func hidString(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }

    private nonisolated static func scanKeyboards() -> [KeyboardDevice] {
        let output = run("/usr/bin/hidutil", arguments: [
            "list",
            "--matching",
            "{\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}",
            "--ndjson"
        ]).output
        var devices: [KeyboardDevice] = []
        var seen = Set<String>()

        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let type = object["type"] as? String, type != "service" { continue }
            let usagePage = intValue(object["PrimaryUsagePage"]) ?? intValue(object["UsagePage"])
            let usage = intValue(object["PrimaryUsage"]) ?? intValue(object["Usage"])
            guard usagePage == 1, usage == 6 else { continue }

            let vendor = UInt64(intValue(object["VendorID"]) ?? 0)
            let product = UInt64(intValue(object["ProductID"]) ?? 0)
            let name = (object["Product"] as? String) ?? ""
            let builtIn = boolValue(object["Built-In"]) || boolValue(object["BuiltIn"])
            let id: String
            if builtIn && vendor == 0 && product == 0 {
                id = "builtin"
            } else if vendor == 0 && product == 0 {
                id = "name:\(name)"
            } else {
                id = "\(vendor)-\(product)"
            }
            guard seen.insert(id).inserted else { continue }
            devices.append(
                KeyboardDevice(
                    id: id,
                    name: name,
                    vendorID: vendor,
                    productID: product,
                    isBuiltIn: builtIn,
                    isConnected: true
                )
            )
        }
        return devices
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private nonisolated static func runHidutil(_ arguments: [String]) throws {
        let result = run("/usr/bin/hidutil", arguments: arguments)
        if result.status != 0 {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemapperError.hidutilFailed(message.isEmpty ? "exit \(result.status)" : message)
        }
    }

    @discardableResult
    private nonisolated static func run(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    enum RemapperError: LocalizedError {
        case encodingFailed
        case hidutilFailed(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "无法编码修饰键映射"
            case .hidutilFailed(let detail):
                return "应用修饰键映射失败：\(detail)"
            }
        }
    }
}

private extension KeyboardDevice {
    var hidutilMatching: String {
        if vendorID != 0 || productID != 0 {
            return "{\"VendorID\":\(vendorID),\"ProductID\":\(productID),\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}"
        }
        let product = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"Product\":\"\(product)\",\"PrimaryUsagePage\":1,\"PrimaryUsage\":6}"
    }

    var preferenceID: String {
        "\(vendorID)-\(productID)-0"
    }
}
