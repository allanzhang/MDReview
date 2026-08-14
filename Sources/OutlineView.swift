import SwiftUI

/// 左侧大纲：从渲染后的标题自动生成，点哪跳哪；页面滚动时反向高亮当前章节。
///
/// 用 ScrollView + LazyVStack 替代 List 的原因（用户实机反馈的三个交互问题）：
/// 1. macOS List 行内含 Button 时，首次点击会被行的 selection/hover 抢占，
///    表现为「部分节标题点不中、需要多次点击、响应慢一拍」；
/// 2. List 行内 Button 的点击区域只覆盖文字本身，行内空白与深层缩进空白均不响应；
/// 3. 自定义行可精确控制整行点击（contentShape）与 hover 反馈，点击即时可靠。
struct OutlineView: View {
    @ObservedObject var renderer: MarkdownRenderer

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(renderer.outline.enumerated()), id: \.element.id) { index, h in
                    OutlineRow(
                        heading: h,
                        isActive: h.id == renderer.activeHeadingID,
                        indent: CGFloat((h.level - 1) * 14),
                        isFirst: index == 0,
                        isLast: index == renderer.outline.count - 1,
                        action: { renderer.scrollTo(h.id) }
                    )
                }
            }
            // 容器留边：让首尾项圆角有呼吸空间
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .navigationTitle("Outline")
    }
}

/// 单行大纲项：整行可点击（含空白与缩进），hover 轻量高亮，激活行 accent 底色。
/// 文字留白充足（horizontal 12 + vertical 7）；首/尾行背景部分圆角，视觉更精致。
private struct OutlineRow: View {
    let heading: Heading
    let isActive: Bool
    let indent: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    /// 行背景形状：首行顶部圆角、末行底部圆角、中间直角（同 sidebar 列表观感）。
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
            Text(heading.text.isEmpty ? "(Untitled)" : heading.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .padding(.leading, indent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            // 层次感：light 下 hover/激活更实（浅灰叠白底 6% 不可见），dark 保持现状
            if isActive {
                rowShape.fill(scheme == .dark
                              ? Color.accentColor.opacity(0.20)
                              : Color.accentColor.opacity(0.26))
            } else if isHovering {
                rowShape.fill(scheme == .dark
                              ? Color.white.opacity(0.06)
                              : Color.black.opacity(0.08))
            }
        }
        .onHover { isHovering = $0 }
    }
}
