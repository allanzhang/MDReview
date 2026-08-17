import SwiftUI
import AppKit

/// 左侧大纲：从渲染后的标题自动生成，点哪跳哪；页面滚动时反向高亮当前章节。
///
/// 用 ScrollView + LazyVStack 而非 List（macOS List 行内嵌 Button 交互有缺陷）：
/// 1. List 行内含 Button 时，首次点击会被行的 selection/hover 抢占；
/// 2. List 行内 Button 的点击区域只覆盖文字本身，行内空白与缩进空白均不响应；
/// 3. 自定义行可精确控制整行点击（contentShape）与 hover 反馈，点击即时可靠。
struct OutlineView: View {
    @ObservedObject var renderer: MarkdownRenderer
    @EnvironmentObject private var doc: DocState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(renderer.outline.enumerated()), id: \.element.id) { index, h in
                        OutlineRow(
                            heading: h,
                            isActive: h.id == renderer.activeHeadingID,
                            indent: CGFloat((h.level - 1) * 14),
                            isFirst: index == 0,
                            isLast: index == renderer.outline.count - 1,
                            action: {
                                if doc.showSource {
                                    NotificationCenter.default.post(name: .mdreviewSourceScroll, object: h.id)
                                } else {
                                    renderer.scrollTo(h.id)
                                }
                            }
                        )
                    }
                }
                // 容器留边：让首尾项圆角有呼吸空间
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .navigationTitle("Outline")
            // 渲染视图滚动到新章节时，大纲列表自动滚到当前项，保持双向同步
            .onChange(of: renderer.activeHeadingID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// 单行大纲项：整行可点击（含空白与缩进），hover 轻量高亮，激活行 accent 底色。
/// 字体层次：h1 常规 primary、次级标题 secondary、激活行 semibold；
/// 留白 horizontal 10 + 层级缩进、vertical 6；首/尾行背景部分圆角。
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
                .truncationMode(.tail)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary.opacity(0.78) : (heading.level > 1 ? Color.secondary : Color.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.leading, 10 + indent)
                .padding(.trailing, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Heading") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(heading.text, forType: .string)
            }
        }
        .background {
            // 层次感：light 下 hover/激活更实（浅灰叠白底 6% 不可见），dark 保持现状
            if isActive {
                rowShape.fill(scheme == .dark
                              ? Color.accentColor.opacity(0.18)
                              : Color.accentColor.opacity(0.22))
            } else if isHovering {
                rowShape.fill(scheme == .dark
                              ? Color.white.opacity(0.07)
                              : Color.black.opacity(0.06))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isActive)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
    }
}
