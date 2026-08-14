import SwiftUI

/// 最近文件列表（与大纲共用侧栏顶部切换器）。
struct RecentView: View {
    var body: some View {
        List {
            ForEach(DocState.shared.recent, id: \.self) { url in
                Button {
                    DocState.shared.open(url)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Recent")
    }
}
