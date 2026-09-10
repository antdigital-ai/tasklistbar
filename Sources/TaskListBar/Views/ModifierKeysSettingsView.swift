import SwiftUI

struct ModifierKeysSettingsView: View {
    @ObservedObject var remapper: ModifierKeyRemapper
    let onClose: () -> Void
    @Environment(\.taskbarAccent) private var accent

    enum Metrics {
        static let width: CGFloat = 440
        static let height: CGFloat = 580
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollView {
                content
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("修饰键")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                Text("每个键盘单独保存修饰键映射，插入后自动套用。")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.55))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.9))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            keyboardPicker
            presetRow

            VStack(spacing: 0) {
                ForEach(Array(ModifierKeyRole.allCases.enumerated()), id: \.element.id) { index, role in
                    ModifierKeyRow(
                        role: role,
                        selection: remapper.configuration.target(for: role)
                    ) { target in
                        remapper.setTarget(target, for: role)
                    }
                    if index < ModifierKeyRole.allCases.count - 1 {
                        Divider().opacity(0.18)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Text("更改只作用于当前选中的键盘。唤醒或重新插入时会自动恢复该键盘的设置。")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            if let error = remapper.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.4))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var currentKeyboard: KeyboardDevice? {
        remapper.keyboards.first { $0.id == remapper.selectedKeyboardID }
    }

    private var currentKeyboardLabel: String {
        currentKeyboard?.displayName ?? "键盘设置"
    }

    private var currentKeyboardSymbol: String {
        if currentKeyboard?.isBuiltIn == true { return "laptopcomputer" }
        return "keyboard"
    }

    private var keyboardPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("键盘")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.42))
            Picker("", selection: Binding(
                get: { remapper.selectedKeyboardID },
                set: { remapper.selectKeyboard($0) }
            )) {
                ForEach(remapper.keyboards) { keyboard in
                    Text(keyboardPickerTitle(keyboard)).tag(keyboard.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(remapper.keyboards.isEmpty)
        }
    }

    private func keyboardPickerTitle(_ keyboard: KeyboardDevice) -> String {
        if keyboard.isConnected {
            return keyboard.displayName
        }
        return "\(keyboard.displayName)（未连接）"
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            PresetChip(
                title: "Windows 键盘",
                subtitle: "交换 ⌃ / ⌘",
                isSelected: remapper.configuration.isWindowsKeyboard
            ) {
                remapper.applyWindowsKeyboardPreset()
            }

            PresetChip(
                title: "恢复默认",
                subtitle: "macOS 原厂",
                isSelected: remapper.configuration.isIdentity
            ) {
                remapper.resetToDefault()
            }

            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Label(currentKeyboardLabel, systemImage: currentKeyboardSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
            Spacer()
            Button(action: onClose) {
                Text("完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(accent.color.opacity(0.9))
                    )
            }
            .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(TaskbarTheme.footerFill)
    }
}

private struct ModifierKeyRow: View {
    let role: ModifierKeyRole
    let selection: ModifierKeyTarget
    let onSelect: (ModifierKeyTarget) -> Void

    var body: some View {
        HStack {
            Text(role.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.92))
            Spacer()
            Picker("", selection: Binding(
                get: { selection },
                set: onSelect
            )) {
                ForEach(ModifierKeyTarget.allCases) { target in
                    Text(target.menuTitle).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 150, alignment: .trailing)
            .tint(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PresetChip: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.55))
            }
            .foregroundStyle(isSelected ? accent.onAccent : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? accent.color.opacity(0.9) : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? accent.color.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.96))
    }
}
