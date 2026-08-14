import SwiftUI

/// 最近文件列表（点工具栏“大纲”按钮可在此与大纲间切换）。
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
        .navigationTitle("最近文件")
    }
}
