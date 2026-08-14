import AppKit
import SwiftUI

struct WindowListView: View {
    @ObservedObject var viewModel: TaskbarViewModel
    @ObservedObject var catalog: WindowCatalog

    var body: some View {
        let bundleID = viewModel.windowListBundleID ?? ""
        let windows = catalog.windows(for: bundleID)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                Button {
                    viewModel.pickWindow(window)
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: viewModel.windowListIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                        Text(window.displayTitle(index: index))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.92))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if window.isMinimized {
                            Image(systemName: "minus")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.primary.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(window.windowID == catalog.frontmostWindowID ? TaskbarTheme.activeFill : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(PressableScaleButtonStyle(pressedScale: 0.98))
                .help(window.displayTitle(index: index))
            }

            if windows.isEmpty {
                Text("没有打开的窗口")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .padding(8)
        .frame(width: Self.panelWidth, alignment: .leading)
        .accessibilityLabel("\(viewModel.windowListAppName) 的窗口")
    }

    static let panelWidth: CGFloat = 268

    static func panelHeight(count: Int) -> CGFloat {
        let rows = max(count, 1)
        return min(CGFloat(rows) * 32 + 16, 320)
    }
}
