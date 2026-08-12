import Foundation

/// Physical modifier key shown in settings (matches System Settings rows).
enum ModifierKeyRole: String, CaseIterable, Codable, Identifiable {
    case capsLock
    case control
    case option
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capsLock: return "大写锁定 (⇪) 键"
        case .control: return "Control (⌃) 键"
        case .option: return "Option (⌥) 键"
        case .command: return "Command (⌘) 键"
        }
    }

    /// USB HID usages for this logical key (left + right where applicable).
    var hidUsages: [UInt64] {
        switch self {
        case .capsLock: return [0x39]
        case .control: return [0xE0, 0xE4]
        case .option: return [0xE2, 0xE6]
        case .command: return [0xE3, 0xE7]
        }
    }
}

/// Destination action for a physical modifier key.
enum ModifierKeyTarget: String, CaseIterable, Codable, Identifiable {
    case capsLock
    case control
    case option
    case command
    case noAction

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .capsLock: return "大写锁定键"
        case .control: return "⌃ Control 键"
        case .option: return "⌥ Option 键"
        case .command: return "⌘ Command 键"
        case .noAction: return "没有动作"
        }
    }

    /// Map a source HID usage to the matching destination usage (preserve left/right).
    func destinationUsage(forSourceUsage source: UInt64) -> UInt64? {
        switch self {
        case .noAction:
            return nil
        case .capsLock:
            return 0x39
        case .control:
            return Self.isRightHand(source) ? 0xE4 : 0xE0
        case .option:
            return Self.isRightHand(source) ? 0xE6 : 0xE2
        case .command:
            return Self.isRightHand(source) ? 0xE7 : 0xE3
        }
    }

    private static func isRightHand(_ usage: UInt64) -> Bool {
        usage == 0xE4 || usage == 0xE5 || usage == 0xE6 || usage == 0xE7
    }
}

struct ModifierKeyConfiguration: Codable, Equatable {
    var capsLock: ModifierKeyTarget
    var control: ModifierKeyTarget
    var option: ModifierKeyTarget
    var command: ModifierKeyTarget

    static let `default` = ModifierKeyConfiguration(
        capsLock: .capsLock,
        control: .control,
        option: .option,
        command: .command
    )

    /// External Windows-layout keyboard: bottom-left Ctrl acts as macOS Command.
    static let windowsKeyboard = ModifierKeyConfiguration(
        capsLock: .capsLock,
        control: .command,
        option: .option,
        command: .control
    )

    func target(for role: ModifierKeyRole) -> ModifierKeyTarget {
        switch role {
        case .capsLock: return capsLock
        case .control: return control
        case .option: return option
        case .command: return command
        }
    }

    mutating func setTarget(_ target: ModifierKeyTarget, for role: ModifierKeyRole) {
        switch role {
        case .capsLock: capsLock = target
        case .control: control = target
        case .option: option = target
        case .command: command = target
        }
    }

    var isIdentity: Bool { self == .default }
    var isWindowsKeyboard: Bool { self == .windowsKeyboard }
}
