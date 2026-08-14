import AppKit
import Combine
import Foundation

/// Persists and applies modifier-key remapping (same idea as System Settings → Keyboard → Modifier Keys).
@MainActor
final class ModifierKeyRemapper: ObservableObject {
    private let defaultsKey = "modifierKeyConfiguration"
    private static let hidUsagePageBase: UInt64 = 0x7000_0000_0

    @Published private(set) var configuration: ModifierKeyConfiguration
    @Published private(set) var lastError: String?

    private var wakeObserver: NSObjectProtocol?

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(ModifierKeyConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }

        apply(configuration)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.apply(self.configuration)
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func setTarget(_ target: ModifierKeyTarget, for role: ModifierKeyRole) {
        var next = configuration
        next.setTarget(target, for: role)
        update(next)
    }

    func applyWindowsKeyboardPreset() {
        update(.windowsKeyboard)
    }

    func resetToDefault() {
        update(.default)
    }

    func reapply() {
        apply(configuration)
    }

    private func update(_ next: ModifierKeyConfiguration) {
        configuration = next
        save()
        apply(next)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func apply(_ config: ModifierKeyConfiguration) {
        // Non-default mappings are owned by KeelBar via hidutil. Clear System Settings
        // mappings first so ⌃/⌘ are not remapped twice.
        if !config.isIdentity {
            clearSystemModifierMappings()
        }

        let mappings = buildUserKeyMapping(from: config)
        do {
            try setUserKeyMapping(mappings)
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
                    // No Action — map to null usage within the keyboard page.
                    result.append([
                        "HIDKeyboardModifierMappingSrc": src,
                        "HIDKeyboardModifierMappingDst": Self.hidUsagePageBase
                    ])
                }
            }
        }

        return result
    }

    private func setUserKeyMapping(_ mappings: [[String: UInt64]]) throws {
        let payload: [String: Any] = ["UserKeyMapping": mappings]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw RemapperError.encodingFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemapperError.hidutilFailed(message ?? "exit \(process.terminationStatus)")
        }
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
        for keyboardID in connectedKeyboardPreferenceIDs() {
            CFPreferencesSetValue("\(prefix)\(keyboardID)" as CFString, nil, appID, user, hostDomain)
        }
        CFPreferencesSynchronize(appID, user, hostDomain)
    }

    private func connectedKeyboardPreferenceIDs() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["list"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var ids = Set<String>()
        // Lines look like: 0x46d    0xc548   ...
        let pattern = #"^(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  let vendorRange = Range(match.range(at: 1), in: text),
                  let productRange = Range(match.range(at: 2), in: text),
                  let vendor = UInt64(String(text[vendorRange]).dropFirst(2), radix: 16),
                  let product = UInt64(String(text[productRange]).dropFirst(2), radix: 16)
            else { return }
            ids.insert("\(vendor)-\(product)-0")
        }
        return Array(ids)
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
