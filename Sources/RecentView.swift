import SwiftUI

/// 最近文件列表（与大纲共用侧栏顶部切换器）。
/// 与 OutlineView 同理弃用 List：ScrollView + LazyVStack 自定义行，
/// 整行可点击（contentShape）、hover 轻量高亮、无 List selection 抢占。
struct RecentView: View {
    @EnvironmentObject var doc: DocState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(doc.recent.enumerated()), id: \.element) { index, url in
                    RecentRow(
                        url: url,
                        isFirst: index == 0,
                        isLast: index == doc.recent.count - 1
                    ) {
                        doc.open(url)
                    }
                }
            }
            // 容器留边：让首尾项圆角有呼吸空间
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .navigationTitle("Recent")
    }
}

/// 单行最近文件：文件名 + 所在目录，整行可点击，hover 轻量高亮。
/// 文字留白充足（horizontal 12 + vertical 7）；首/尾行背景部分圆角。
private struct RecentRow: View {
    let url: URL
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    private var rowShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 8 : 0,
            bottomLeadingRadius: isLast ? 8 : 0,
            bottomTrailingRadius: isLast ? 8 : 0,
            topTrailingRadius: isFirst ? 8 : 0
        )
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isHovering {
                // 层次感：light 下 hover 更实（浅灰叠白底不可见），dark 保持现状
                rowShape.fill(scheme == .dark
                              ? Color.white.opacity(0.06)
                              : Color.black.opacity(0.08))
            }
        }
        .onHover { isHovering = $0 }
    }
}
