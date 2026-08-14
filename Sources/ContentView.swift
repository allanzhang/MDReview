import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var doc: DocState
    @StateObject private var renderer = MarkdownRenderer()
    @State private var searchText = ""
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView(columnVisibility: $doc.columnVisibility) {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: doc.url) { _, _ in DispatchQueue.main.async { renderCurrent() } }
        .onAppear { DispatchQueue.main.async { renderCurrent() } }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Outline / Recent 切换器：仅图标、无文字 Label，保持侧栏顶部干净（macOS 26 自动 Liquid Glass 样式）
            Picker("View", selection: $doc.showOutline) {
                Image(systemName: "list.bullet").tag(true)
                Image(systemName: "clock").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(10)
            .frame(maxWidth: .infinity)
            Divider()
            if doc.showOutline {
                OutlineView(
                    outline: renderer.outline,
                    onSelect: { id in renderer.scrollTo(id) },
                    activeID: renderer.activeHeadingID
                )
            } else {
                RecentView()
            }
        }
        // 移除系统默认加在工具栏的 sidebar toggle，改由 detail panel 控制
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .top) {
            ReaderWebView(renderer: renderer)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
            // 源码态：只读覆盖在 WebView 之上，保留渲染状态不卸载
            if doc.showSource {
                SourceView(text: doc.rawText)
            }
            if showSearch {
                SearchBar(text: $searchText,
                          count: renderer.searchCount,
                          current: renderer.searchCurrent,
                          onNext: { renderer.searchNext() },
                          onPrev: { renderer.searchPrev() },
                          onClose: {
                              showSearch = false
                              searchText = ""
                              renderer.search("")
                          })
            }
        }
        .onChange(of: searchText) { _, _ in DispatchQueue.main.async { renderer.search(searchText) } }
        // 折叠/展开侧边栏的按钮放在 Content Panel 的工具栏，符合用户的交互预期
        .toolbar { detailToolbar }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                // 无动画直接切换：NavigationSplitView 列动画会驱动 detail 区 WKWebView 连续 resize 重排，长文档下明显卡顿
                doc.columnVisibility = (doc.columnVisibility == .all) ? .detailOnly : .all
            } label: {
                Label("Sidebar", systemImage: doc.columnVisibility == .all ? "sidebar.left" : "sidebar.right")
            }
            .help(doc.columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar")
        }
        ToolbarItem(placement: .navigation) {
            Button { openPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open Markdown File")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showSearch.toggle() } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search in Document")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                withAnimation { doc.showSource.toggle() }
            } label: {
                Label("Source", systemImage: doc.showSource ? "doc.richtext" : "doc.plaintext")
            }
            .help(doc.showSource ? "Switch to Rendered View" : "Switch to Source View")
        }
        ToolbarItem(placement: .automatic) {
            Button { openInExternalEditor() } label: { Label("External Editor", systemImage: "pencil.and.outline") }
                .help("Open in External Editor (Cmd+E)")
                .keyboardShortcut("e", modifiers: .command)
                .disabled(doc.url == nil)
        }
    }

    private func renderCurrent() {
        guard let url = doc.url else { return }
        // 整体重载页面（render 内部已重置 pageLoaded），高亮随之清空，故直接复位计数即可。
        // 注意：不要在 loadHTMLString 完成前调用 evaluateJavaScript（如旧版 search("")），
        // 否则页面未就绪会触发 "Request to run JavaScript failed" 持续报错。
        renderer.searchCount = 0
        renderer.searchCurrent = 0
        searchText = ""
        renderer.render(doc.rawText, baseURL: url.deletingLastPathComponent())
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!,
                                     UTType(filenameExtension: "markdown")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let u = panel.url {
            DocState.shared.open(u)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    var fileURL: URL?
                    if let data = item as? Data {
                        fileURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        fileURL = u
                    }
                    if let u = fileURL {
                        DispatchQueue.main.async { DocState.shared.open(u) }
                    }
                }
                return true
            }
        }
        return false
    }

    /// 用外部编辑器打开当前文件：优先 Cursor / VSCode，未检测到则退回系统默认关联应用。
    private func openInExternalEditor() {
        guard let url = doc.url else { return }
        let userApps = NSHomeDirectory() + "/Applications"
        let candidates = [
            "/Applications/Cursor.app",
            "/Applications/Visual Studio Code.app",
            userApps + "/Cursor.app",
            userApps + "/Visual Studio Code.app"
        ]
        var appURL: URL?
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { appURL = URL(fileURLWithPath: c); break }
        }
        if let appURL {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 源码视图：只读展示当前 Markdown 原文（等宽字体、可选中、自适应明暗背景）。
struct SourceView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 顶部搜索条：输入实时搜索，支持 上/下 跳转与关闭。
/// macOS 26+ 使用系统 Liquid Glass 卡片（.glassEffect），旧系统回退毛玻璃材质。
struct SearchBar: View {
    @Binding var text: String
    let count: Int
    let current: Int
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .frame(minWidth: 220)
            if count > 0 {
                Text("\(current)/\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button { onPrev() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(count == 0)
            Button { onNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(count == 0)
            Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(glassBackground)
        .padding(12)
    }

    @ViewBuilder
    private var glassBackground: some View {
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
    }
}
