import SwiftUI
import AppKit

/// 大纲条目树节点：由渲染出的扁平 heading 数组按标题层级构建。
private struct OutlineNode: Identifiable, Equatable {
    let heading: Heading
    let children: [OutlineNode]

    var id: String { heading.id }
    var hasChildren: Bool { !children.isEmpty }
}

/// 由扁平 [Heading] 构建标题树：Level 递增的标题归为上一个（层级更浅）标题的子节点；
/// 跳过层级（如 H1 后直接 H3）时 H3 直接挂到 H1 下，展示缩进仍按自身 level 计算。
private func buildOutlineTree(_ headings: [Heading]) -> [OutlineNode] {
    var roots: [OutlineNode] = []
    _ = appendOutlineLevels(headings, from: 0, parentLevel: 0, into: &roots)
    return roots
}

private func appendOutlineLevels(_ headings: [Heading], from start: Int, parentLevel: Int, into out: inout [OutlineNode]) -> Int {
    var i = start
    while i < headings.count {
        let h = headings[i]
        guard h.level > parentLevel else { break }   // 同级或更浅的标题：属于外层，交还上层处理
        var children: [OutlineNode] = []
        i = appendOutlineLevels(headings, from: i + 1, parentLevel: h.level, into: &children)
        out.append(OutlineNode(heading: h, children: children))
    }
    return i
}

/// 按折叠状态展开成可见的扁平节点序列（前序遍历，折叠的子树整体隐藏）。
private func flattenedNodes(_ nodes: [OutlineNode], collapsed: Set<String>) -> [OutlineNode] {
    var result: [OutlineNode] = []
    func walk(_ list: [OutlineNode]) {
        for node in list {
            result.append(node)
            if !collapsed.contains(node.id) { walk(node.children) }
        }
    }
    walk(nodes)
    return result
}

/// 层级展示样式（缩进 + 字号 + 字重 + 文字色，四重区分；深浅色各自适配）。
private struct LevelStyle {
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let color: Color
}

private func levelStyle(for level: Int, scheme: ColorScheme) -> LevelStyle {
    // 浅色文字色整体提亮一档（26/3D/54/73），避免近黑粗体的沉重感；
    // 深色保持原有亮度梯度。层级仍靠 缩进+字号+字重+文字色 四重区分。
    switch min(max(level, 1), 4) {
    case 1:
        return LevelStyle(fontSize: 13, fontWeight: .semibold,
                          color: scheme == .dark ? Color(hex: 0xF2F2F2) : Color(hex: 0x262626))
    case 2:
        return LevelStyle(fontSize: 12.5, fontWeight: .medium,
                          color: scheme == .dark ? Color(hex: 0xDBDBDB) : Color(hex: 0x3D3D3D))
    case 3:
        return LevelStyle(fontSize: 12, fontWeight: .regular,
                          color: scheme == .dark ? Color(hex: 0xC4C4C4) : Color(hex: 0x545454))
    default: // H4 及更深层级
        return LevelStyle(fontSize: 11.5, fontWeight: .regular,
                          color: scheme == .dark ? Color(hex: 0x9A9A9A) : Color(hex: 0x737373))
    }
}

/// 层级缩进：H1→0 / H2→12 / H3→24 / H4+→36（单位 pt）。
private func levelIndent(for level: Int) -> CGFloat {
    CGFloat(min(max(level, 1), 4) - 1) * 12
}

/// 行状态底色：中性灰圆角底（Codex 式克制语言），hover 更浅、选中加深；文字颜色不随状态变化。
private func rowFillColor(isActive: Bool, scheme: ColorScheme) -> Color {
    if isActive {
        return scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09)
    }
    return scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04)
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// 左侧大纲：从渲染后的标题自动生成，点哪跳哪；页面滚动时反向高亮当前章节。
///
/// 用 ScrollView + VStack 自定义行（macOS List 行内嵌 Button 交互有缺陷）：
/// 1. List 行内含 Button 时，首次点击会被行的 selection/hover 抢占；
/// 2. List 行内 Button 的点击区域只覆盖文字本身，行内空白与缩进空白均不响应；
/// 3. 自定义行可精确控制整行点击（contentShape）与 hover 反馈，点击即时可靠。
/// 用普通 VStack 而非 LazyVStack：大纲需 ScrollViewReader.scrollTo 把当前激活条目
/// 可靠地滚入视图（Lazy 下未渲染的条目无法定位），大纲条目数量级较小，全量渲染无压力。
struct OutlineView: View {
    @ObservedObject var renderer: MarkdownRenderer
    @EnvironmentObject private var doc: DocState

    @State private var tree: [OutlineNode] = []
    @State private var collapsed: Set<String> = []
    /// 点击条目后短暂抑制"大纲跟随滚动"，避免刚点中的条目被强行滚动居中。
    @State private var suppressFollow = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleNodes) { node in
                            OutlineRow(
                                node: node,
                                isCollapsed: collapsed.contains(node.id),
                                isActive: node.id == renderer.activeHeadingID,
                                action: { select(node) },
                                toggleCollapse: { toggleCollapse(node) }
                            )
                            .transition(.opacity)   // 折叠/展开时子行淡入淡出
                        }
                    }
                    // 列表容器留边：左右不让条目贴死面板边界，上下预留 8pt 呼吸空间
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                // 隐藏滚动条：大纲已有高亮+跟随滚动定位，窄栏里常驻滚动条太扎眼；
                // trackpad/滚轮滚动不受影响
                .scrollIndicators(.hidden)
                // 双向同步：正文滚动 → active 变化 → 大纲跟随滚动，保证当前条目可视
                .onChange(of: renderer.activeHeadingID) { _, newID in
                    guard !suppressFollow, let newID else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
        // 标签栏与下方大纲列表之间的 10pt 垂直留白
        .padding(.top, 10)
        .onAppear { rebuild(renderer.outline) }
        .onChange(of: renderer.outline) { _, outline in rebuild(outline) }
    }

    private var visibleNodes: [OutlineNode] { flattenedNodes(tree, collapsed: collapsed) }

    private func rebuild(_ outline: [Heading]) {
        tree = buildOutlineTree(outline)
        collapsed = []
    }

    private func toggleCollapse(_ node: OutlineNode) {
        withAnimation(.easeOut(duration: 0.15)) {
            if collapsed.contains(node.id) { collapsed.remove(node.id) }
            else { collapsed.insert(node.id) }
        }
    }

    private func select(_ node: OutlineNode) {
        // 刚点中的条目本来就可见，抑制跟随滚动，避免被强制滚动居中
        suppressFollow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { suppressFollow = false }
        renderer.activeHeadingID = node.id
        renderer.saveProgress(node.id)
        if doc.showSource {
            NotificationCenter.default.post(name: .mdreviewSourceScroll, object: node.id)
        } else {
            renderer.scrollTo(node.id)
        }
    }
}

/// 单行大纲项：整行可点击（含空白与缩进），hover/激活行圆角底色，文字颜色不因状态变化。
/// 层级由【缩进 + 字号 + 字重 + 文字色】四重区分；有子标题的节点左侧渲染折叠三角（16pt 占位，叶子留空对齐）。
private struct OutlineRow: View {
    let node: OutlineNode
    let isCollapsed: Bool
    let isActive: Bool
    let action: () -> Void
    let toggleCollapse: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    private var style: LevelStyle { levelStyle(for: node.heading.level, scheme: scheme) }

    var body: some View {
        HStack(spacing: 2) {
            // 折叠三角占位 16pt：有子标题渲染 ▶/▼，叶子节点留空保持同级文字对齐
            if node.hasChildren {
                Button(action: toggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand" : "Collapse")
            } else {
                Color.clear
                    .frame(width: 16, height: 16)
            }
            Text(node.heading.text.isEmpty ? "(Untitled)" : node.heading.text)
                .font(.system(size: style.fontSize, weight: style.fontWeight))
                .foregroundStyle(style.color)
                .lineLimit(1)               // 强制单行
                .truncationMode(.tail)      // 超长末尾截断显示 …
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8 + levelIndent(for: node.heading.level))
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isActive || isHovering {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(rowFillColor(isActive: isActive, scheme: scheme))
            }
        }
        // 整行（含缩进条与左右留白）都响应点击，三角 Button 在自己 16pt 区域内优先拦截，
        // 避免"点行边缘没反应、要点好几次"的不灵敏感
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .onHover { isHovering = $0 }
        // hover 弹出完整标题 tooltip（原生 macOS 帮助提示）
        .help(node.heading.text.isEmpty ? "(Untitled)" : node.heading.text)
        .contextMenu {
            Button("Copy Heading") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.heading.text, forType: .string)
            }
        }
    }
}
