import SwiftUI

/// 左侧大纲：从渲染后的标题自动生成，点哪跳哪；页面滚动时反向高亮当前章节。
/// 独立 @ObservedObject 观察 renderer（outline / activeHeadingID），
/// 高频滚动更新只触发本列表 diff，不牵连 ContentView 整树重算。
struct OutlineView: View {
    @ObservedObject var renderer: MarkdownRenderer

    var body: some View {
        List(renderer.outline) { h in
            Button { renderer.scrollTo(h.id) } label: {
                Text(h.text.isEmpty ? "(Untitled)" : h.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat((h.level - 1) * 14))
            .listRowBackground(h.id == renderer.activeHeadingID ? Color.accentColor.opacity(0.18) : nil)
        }
        .listStyle(.sidebar)
        .navigationTitle("Outline")
    }
}
