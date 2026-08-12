import SwiftUI

struct ModifierKeysSettingsView: View {
    @ObservedObject var remapper: ModifierKeyRemapper
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskbarTheme.menuTint)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(2)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("修饰键")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text("为外置键盘调整 Control / Command 等键位，效果与系统设置一致。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            Text("更改会立即生效；唤醒后会自动恢复。启用「Windows 键盘」时会接管系统修饰键设置，避免与系统设置重复映射。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
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
            Label("键盘设置", systemImage: "keyboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button(action: onClose) {
                Text("完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(TaskbarTheme.startButton.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18))
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
                .foregroundStyle(.white.opacity(0.92))
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
            .tint(.white)
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

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? TaskbarTheme.startButton.opacity(0.85) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? TaskbarTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
