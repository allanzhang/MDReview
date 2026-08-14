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
                ForEach(renderer.outline) { h in
                    OutlineRow(
                        heading: h,
                        isActive: h.id == renderer.activeHeadingID,
                        indent: CGFloat((h.level - 1) * 14),
                        action: { renderer.scrollTo(h.id) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Outline")
    }
}

/// 单行大纲项：整行可点击（含空白与缩进），hover 轻量高亮，激活行 accent 底色。
private struct OutlineRow: View {
    let heading: Heading
    let isActive: Bool
    let indent: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(heading.text.isEmpty ? "(Untitled)" : heading.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.leading, indent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            Color.accentColor.opacity(0.18)
        } else if isHovering {
            Color.primary.opacity(0.06)
        }
    }
}
