import SwiftUI

struct PermissionsView: View {
    @ObservedObject var center: PermissionCenter
    let onClose: () -> Void
    @Environment(\.taskbarAccent) private var accent

    enum Metrics {
        static let width: CGFloat = 400
        static let height: CGFloat = 600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(TaskbarTheme.hairline)
                .frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    section("必需", items: center.requiredItems)
                    section("功能权限", items: center.optionalItems)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { center.setPageVisible(true) }
        .onDisappear { center.setPageVisible(false) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("权限")
                    .font(.system(size: 16, weight: .semibold))
                Text("打开后任务栏才能避开窗口、显示日程和标题")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.68))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(PressableScaleButtonStyle())
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: center.hasRequired ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(center.hasRequired ? Color(red: 0.22, green: 0.72, blue: 0.42) : accent.color)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(center.hasRequired ? "必需权限已开启" : "还差 \(center.missingRequiredTitle)")
                    .font(.system(size: 13, weight: .semibold))
                Text(center.hasRequired
                     ? (center.missingCount == 0 ? "可选权限也可以按需打开" : "还可以开启 \(center.missingCount) 项功能权限")
                     : "不开启辅助功能，最大化窗口会挡住底栏")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func section(_ title: String, items: [PermissionItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.42))
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PermissionRow(item: item) {
                        center.open(item.kind)
                    }
                    if index < items.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 48)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(center.hasRequired ? "返回任务栏即可使用" : "在系统设置里打开 KeelBar，再回到这里查看状态")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.42))
            Spacer(minLength: 0)
            if center.hasRequired {
                Button("完成", action: onClose)
                    .buttonStyle(PermissionActionButtonStyle(filled: true, accent: accent.color, onAccent: accent.onAccent))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TaskbarTheme.footerFill.opacity(0.45))
    }
}

private struct PermissionRow: View {
    let item: PermissionItem
    let action: () -> Void
    @Environment(\.taskbarAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.isGranted ? Color(red: 0.22, green: 0.72, blue: 0.42) : accent.color)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill((item.isGranted ? Color(red: 0.22, green: 0.72, blue: 0.42) : accent.color).opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.kind.title)
                        .font(.system(size: 13, weight: .medium))
                    if item.kind.isRequired {
                        Text("必需")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accent.onAccent)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule(style: .continuous).fill(accent.color))
                    }
                }
                Text(item.kind.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if item.isGranted {
                Text("已开启")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.16, green: 0.58, blue: 0.34))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.22, green: 0.72, blue: 0.42).opacity(0.16))
                    )
            } else {
                Button(item.state == .denied ? "去设置" : "去开启", action: action)
                    .buttonStyle(PermissionActionButtonStyle(filled: true, accent: accent.color, onAccent: accent.onAccent))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PermissionActionButtonStyle: ButtonStyle {
    let filled: Bool
    let accent: Color
    let onAccent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? onAccent : accent)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? accent : accent.opacity(0.14))
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}
