import SwiftUI

/// 最近文件列表（与大纲共用侧栏顶部切换器）。
/// 与 OutlineView 同理弃用 List：ScrollView + LazyVStack 自定义行，
/// 整行可点击（contentShape）、hover 轻量高亮、无 List selection 抢占。
struct RecentView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(DocState.shared.recent, id: \.self) { url in
                    RecentRow(url: url) {
                        DocState.shared.open(url)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Recent")
    }
}

/// 单行最近文件：文件名 + 所在目录，整行可点击，hover 轻量高亮。
private struct RecentRow: View {
    let url: URL
    let action: () -> Void

    @State private var isHovering = false

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
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovering ? Color.primary.opacity(0.06) : nil)
        .onHover { isHovering = $0 }
    }
}
