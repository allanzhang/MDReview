import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主界面。renderer 用 @State 持有但不观察：@State 对引用类型仅管理生命周期，
/// 其 @Published 变化不会触发 ContentView 整树重算（activeHeadingID 滚动高频更新是
/// 之前「点任何按钮都卡」的根因）。需要响应 renderer 状态的子视图各自 @ObservedObject。
@MainActor
struct ContentView: View {
    @EnvironmentObject var doc: DocState
    /// 窗口实际外观（system 模式跟随系统、手动模式由 preferredColorScheme 强制），用于外观按钮图标。
    @Environment(\.colorScheme) private var systemScheme
    @State private var renderer = MarkdownRenderer()
    @State private var searchText = ""
    /// 搜索防抖（大文档 TreeWalker 全文遍历昂贵，输入停顿 250ms 才执行）。
    @State private var searchDebounce: DispatchWorkItem?
    /// 拖拽悬停状态（用于高亮反馈）。
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $doc.columnVisibility) {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        // 工具栏下边界层次：light 下系统 Liquid Glass 与内容区几乎同色。
        // 用顶部柔和渐变阴影（工具栏向下投射的光晕）而非 1px 硬线，层次更自然；
        // dark 系统自带边界清晰，保持不动
        .overlay(alignment: .top) {
            if systemScheme != .dark {
                LinearGradient(
                    colors: [Color.black.opacity(0.10), Color.black.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 5)
                .allowsHitTesting(false)
            }
        }
        // 打开文档与外部编辑热更新都会更新 rawText，统一由此触发渲染（url 变化必伴随 rawText 变化）
        .onChange(of: doc.rawText) { _, _ in DispatchQueue.main.async { renderCurrent() } }
        // 外观切换：即时注入 JS 生效，不重载页面（保留滚动位置与渲染状态）
        .onChange(of: doc.appearance) { _, mode in renderer.applyAppearance(mode) }
        .onAppear { DispatchQueue.main.async { renderCurrent() } }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // 视图切换：两个大按钮（图标 + 文字），替代原 segmented Picker（去掉 View 标签、拉宽拉长）
            HStack(spacing: 4) {
                SidebarSegment(title: "Outline", systemImage: "list.bullet",
                               isSelected: doc.showOutline) { doc.showOutline = true }
                SidebarSegment(title: "History", systemImage: "clock",
                               isSelected: !doc.showOutline) { doc.showOutline = false }
            }
            .padding(4)
            .background {
                // 底座层次：light 下深灰底 + 细描边（组件边界清晰），dark 下保持浅白底
                RoundedRectangle(cornerRadius: 9)
                    .fill(systemScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(systemScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            Divider()
            if doc.showOutline {
                OutlineView(renderer: renderer)
            } else {
                RecentView()
            }
        }
        // 移除系统默认加在工具栏的 sidebar toggle，改由 detail panel 控制
        .toolbar(removing: .sidebarToggle)
        // 侧栏最小宽度：防 Outline/History 按钮文字换行（拉到最窄也不难看）
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        // 侧栏层次感：light 下叠实背景与内容区明确分界（sidebar 系统材质在 light 下太透）
        .background {
            if systemScheme == .dark {
                Color.clear
            } else {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .top) {
            // WebView 始终保留实例（NSViewRepresentable 首次 make 后复用），空状态覆盖其上
            ReaderWebView(renderer: renderer)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                }
                .overlay {
                    // 拖拽视觉反馈：文件悬停时显示 accent 边框
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(6)
                    }
                }
            // 无文档空状态引导
            if doc.url == nil {
                EmptyStateView()
            }
            // 源码态：只读覆盖在 WebView 之上，保留渲染状态不卸载
            if doc.showSource && doc.url != nil {
                SourceView(text: doc.rawText)
            }
        }
        .onChange(of: searchText) { _, newValue in
            // 防抖：连续输入不触发搜索，停顿 250ms 后执行一次（避免大文档全文遍历打满 WebContent）
            searchDebounce?.cancel()
            let item = DispatchWorkItem { renderer.search(newValue) }
            searchDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
        // 窗口标题：显示当前文件名与所在目录（无文档时显示 App 名）
        .navigationTitle(doc.url?.lastPathComponent ?? "MDReview")
        .navigationSubtitle(doc.url?.deletingLastPathComponent().path ?? "")
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
            // 搜索：呼出浮动面板（标题栏中央悬空覆盖，原布局不变）
            Button {
                SearchPanelController.shared.toggle(renderer: renderer,
                                                    text: $searchText,
                                                    onClose: {
                                                        // 关闭面板 + 清空搜索
                                                        SearchPanelController.shared.hide()
                                                        searchText = ""
                                                        renderer.search("")
                                                    })
            } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search in Document")
        }
        // 外观切换：单按钮，太阳/月亮图标高亮代表当前状态。
        // System（默认）→ 点击临时覆盖为相反外观 → 再点回到 System（不持久化）
        ToolbarItem(placement: .automatic) {
            Button {
                doc.toggleAppearance()
            } label: {
                Image(systemName: appearanceIconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isManualAppearance ? Color.white : Color.primary)
                    .padding(6)
                    .background {
                        if isManualAppearance {
                            Circle().fill(Color.accentColor)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isManualAppearance ? "Override active — click to follow system" : "Follow system — click to override")
        }
        // 次级功能收纳进 More 菜单，保持工具栏克制（源码对照 / 外部编辑器）
        ToolbarItem(placement: .automatic) {
            Menu {
                Button {
                    withAnimation { doc.showSource.toggle() }
                } label: {
                    Label(doc.showSource ? "Rendered View" : "Source View",
                          systemImage: doc.showSource ? "doc.richtext" : "doc.plaintext")
                }
                Divider()
                Button {
                    openInExternalEditor()
                } label: {
                    Label("Open in External Editor", systemImage: "pencil.and.outline")
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(doc.url == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More")
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Export as HTML…") { exportHTML() }
                Button("Export as PDF…") { exportPDF() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export Document")
            .disabled(doc.url == nil)
        }
    }

    // MARK: - 外观按钮辅助

    /// 是否处于手动覆盖状态（非跟随系统），用于按钮高亮。
    private var isManualAppearance: Bool { doc.appearance != .system }
    /// 当前生效是否暗色：手动模式按选择，system 模式按窗口实际外观（colorScheme）。
    private var isDarkEffective: Bool {
        if doc.appearance == .system { return systemScheme == .dark }
        return doc.appearance == .dark
    }
    /// 外观按钮图标：暗 → 月亮，亮 → 太阳。
    private var appearanceIconName: String { isDarkEffective ? "moon" : "sun.max" }

    private func renderCurrent() {
        guard let url = doc.url else { return }
        // 整体重载页面（render 内部已重置 pageLoaded），高亮随之清空，故直接复位计数即可。
        // 注意：不要在 loadHTMLString 完成前调用 evaluateJavaScript（如旧版 search("")），
        // 否则页面未就绪会触发 "Request to run JavaScript failed" 持续报错。
        renderer.searchCount = 0
        renderer.searchCurrent = 0
        searchText = ""
        renderer.render(doc.rawText, baseURL: url.deletingLastPathComponent(),
                        docName: url.lastPathComponent, appearance: doc.appearance)
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

    /// 导出为静态 HTML 快照（渲染后的 DOM + 内联样式，Preview/浏览器均可打开）。
    private func exportHTML() {
        guard let url = doc.url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".html"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                try await renderer.exportHTML(to: dest)
            } catch {
                await MainActor.run { presentExportError(error) }
            }
        }
    }

    /// 导出为 PDF（基于当前渲染结果，多页分页，含高亮/公式/样式）。
    private func exportPDF() {
        guard let url = doc.url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                try await renderer.exportPDF(to: dest)
            } catch {
                await MainActor.run { presentExportError(error) }
            }
        }
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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

/// 无文档时的空状态引导页：提示打开/拖拽方式，克制不喧宾夺主。
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("MDReview")
                .font(.title2)
                .fontWeight(.medium)
            Text("Open a Markdown file or drop one here")
                .foregroundStyle(.secondary)
            Text("Toolbar  Open  ·  Drag & Drop  ·  Recent")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 侧边栏视图切换按钮：图标 + 文字，选中态 accent 高亮，均分拉宽、垂直拉长。
private struct SidebarSegment: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7).fill(Color.accentColor)
            } else if isHovering {
                // hover 反馈：light 深灰 / dark 浅白，组件可交互性一目了然
                RoundedRectangle(cornerRadius: 7)
                    .fill(scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06))
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .onHover { isHovering = $0 }
    }
}

/// 源码视图：只读展示当前 Markdown 原文。
/// 用 NSTextView（AppKit 文本系统）承载而非 SwiftUI Text——后者渲染 MB 级大文本时
/// 布局开销极高，是「点击源码按钮卡顿」的根因。
struct SourceView: View {
    let text: String

    var body: some View {
        SourceTextView(text: text)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// NSTextView 的 SwiftUI 包装：可滚动、可选中、等宽字体。
struct SourceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 28, height: 28)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.string = text
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }
}

/// 搜索框：Spotlight 式悬浮卡片——点击搜索按钮呼出，横向居中于内容区顶部（标题区域）。
/// 玻璃材质 + 悬浮阴影 + 细描边，大字号输入；仅观察 renderer 的 searchCount/searchCurrent。
struct SearchBar: View {
    @ObservedObject var renderer: MarkdownRenderer
    @Binding var text: String
    let onClose: () -> Void
    /// 出现即聚焦输入框。
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFocused)
                .onAppear {
                    // 延迟聚焦：等待浮动面板成为 key window 后输入框才可聚焦
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFocused = true }
                }
            if renderer.searchCount > 0 {
                Text("\(renderer.searchCurrent)/\(renderer.searchCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button { renderer.searchPrev() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(renderer.searchCount == 0)
            Button { renderer.searchNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(renderer.searchCount == 0)
            Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            // 层次感：light 下用偏实底色 + 深描边（毛玻璃太透导致边界模糊）；
            // dark 下保持 ultraThinMaterial 毛玻璃（透明浮动面板里 glassEffect 会黑底）
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(scheme == .dark
                      ? AnyShapeStyle(.ultraThinMaterial)
                      : AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.62)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
    }
}
