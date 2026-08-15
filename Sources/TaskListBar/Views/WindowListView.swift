import AppKit
import SwiftUI

struct WindowListView: View {
    @ObservedObject var viewModel: TaskbarViewModel
    @ObservedObject var catalog: WindowCatalog

    var body: some View {
        let bundleID = viewModel.windowListBundleID ?? ""
        let windows = catalog.windows(for: bundleID)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                Button {
                    viewModel.pickWindow(window)
                } label: {
                    HStack(spacing: 6) {
                        Text(window.displayTitle(index: index))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary.opacity(window.isMinimized ? 0.45 : 0.92))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if window.windowID == catalog.frontmostWindowID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.primary.opacity(0.45))
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(window.windowID == catalog.frontmostWindowID ? TaskbarTheme.activeFill : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if windows.isEmpty {
                Text("没有打开的窗口")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.45))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
            }
        }
        .padding(.vertical, 4)
        .frame(width: Self.panelWidth, alignment: .leading)
        .accessibilityLabel("\(viewModel.windowListAppName) 的窗口")
    }

    static let panelWidth: CGFloat = 196

    static func panelHeight(count: Int) -> CGFloat {
        let rows = max(count, 1)
        return min(CGFloat(rows) * 22 + 8, 280)
    }
}
