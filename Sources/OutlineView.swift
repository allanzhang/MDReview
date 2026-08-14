import SwiftUI

/// 左侧大纲：从渲染后的标题自动生成，点哪跳哪；页面滚动时反向高亮当前章节。
struct OutlineView: View {
    let outline: [Heading]
    let onSelect: (String) -> Void
    /// 当前可视章节 id（由页面滚动回传），用于反向高亮。
    let activeID: String?

    var body: some View {
        List(outline) { h in
            Button { onSelect(h.id) } label: {
                Text(h.text.isEmpty ? "(无标题)" : h.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat((h.level - 1) * 14))
            .listRowBackground(h.id == activeID ? Color.accentColor.opacity(0.18) : nil)
        }
        .listStyle(.sidebar)
        .navigationTitle("大纲")
    }
}
