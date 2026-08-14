import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主界面。renderer 用 @State 持有但不观察：@State 对引用类型仅管理生命周期，
/// 其 @Published 变化不会触发 ContentView 整树重算。需要响应 renderer 状态的
/// 子视图各自 @ObservedObject。
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
    /// 当前文档字数（窗口副标题显示）。
    @State private var wordCount = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $doc.columnVisibility) {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        // 工具栏下边界层次：light 下用顶部柔和渐变阴影（工具栏向下投射的光晕）增强层次；
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
        .onChange(of: doc.rawText) { _, _ in
            wordCount = Self.countWords(doc.rawText)
            DispatchQueue.main.async { renderCurrent() }
        }
        // 外观切换：即时注入 JS 生效，不重载页面（保留滚动位置与渲染状态）
        .onChange(of: doc.appearance) { _, mode in renderer.applyAppearance(mode) }
        .onAppear {
            DispatchQueue.main.async {
                renderCurrent()
                restoreLastDocument()
            }
        }
        // 菜单命令（File/View）经 NotificationCenter 转发到这里执行
        .onReceive(NotificationCenter.default.publisher(for: .mdreviewMenuAction)) { note in
            guard let action = note.object as? MenuAction else { return }
            handleMenuAction(action)
        }
        // 记忆窗口位置/大小（AppKit frame autosave，跨启动恢复）
        .background(WindowFrameAutosave())
    }

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .openPanel: openPanel()
        case .toggleSidebar:
            doc.columnVisibility = (doc.columnVisibility == .all) ? .detailOnly : .all
        case .toggleSource: withAnimation { doc.showSource.toggle() }
        case .appearanceSystem: doc.appearance = .system
        case .appearanceLight: doc.appearance = .light
        case .appearanceDark: doc.appearance = .dark
        case .exportHTML: exportHTML()
        case .exportPDF: exportPDF()
        case .openInExternalEditor: openInExternalEditor()
        case .revealInFinder: revealInFinder()
        case .openRecent(let url): DocState.shared.open(url)
        case .clearRecent: DocState.shared.clearRecent()
        }
    }

    /// 启动时若未由 Finder 打开文件，则恢复上次文档（文件仍存在时）。
    private func restoreLastDocument() {
        // 延迟一拍，等 application(_:open:)（Finder 双击）先到达，避免与其竞态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !DocState.shared.didOpenViaSystem, let url = DocState.shared.lastDocumentURL else { return }
            DocState.shared.open(url)
        }
    }

    private static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for ch in text {
            if ch.isWhitespace { inWord = false }
            else if !inWord { inWord = true; count += 1 }
        }
        return count
    }

    /// 窗口副标题：目录 + 字数。
    private var subtitleText: String {
        guard let url = doc.url else { return "" }
        let dir = url.deletingLastPathComponent().path
        return wordCount > 0 ? "\(dir) · \(wordCount) words" : dir
    }

    /// 呼出/关闭搜索面板；⌘F 时若文档有选中文字则预填搜索词。
    private func toggleSearch() {
        if SearchPanelController.shared.isVisible {
            SearchPanelController.shared.hide()
            searchText = ""
            renderer.search("")
            return
        }
        renderer.selectedText { sel in
            let t = sel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { self.searchText = t }
            SearchPanelController.shared.toggle(renderer: renderer, text: $searchText, onClose: {
                SearchPanelController.shared.hide()
                searchText = ""
                renderer.search("")
            })
        }
    }

    private func copySelection() {
        NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
    }

    private func revealInFinder() {
        guard let url = doc.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // 视图切换：两个大按钮（图标 + 文字），无自绘底座/描边
            HStack(spacing: 4) {
                SidebarSegment(title: "Outline", systemImage: "list.bullet",
                               isSelected: doc.showOutline) { doc.showOutline = true }
                SidebarSegment(title: "Recent", systemImage: "clock",
                               isSelected: !doc.showOutline) { doc.showOutline = false }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
                EmptyStateView(onOpen: { openPanel() })
            }
            // 源码态：只读覆盖在 WebView 之上，保留渲染状态不卸载
            if doc.showSource && doc.url != nil {
                SourceView(text: doc.rawText)
            }
        }
        .contextMenu {
            Button("Copy") { copySelection() }
            if doc.url != nil {
                Divider()
                Button("Reveal in Finder") { revealInFinder() }
                Button("Open in External Editor") { openInExternalEditor() }
                Divider()
                Button("Export as HTML…") { exportHTML() }
                Button("Export as PDF…") { exportPDF() }
            }
        }
        .overlay(alignment: .topLeading) {
            // 阅读进度条：独立子视图观察 renderer，进度变化时精准重绘
            ReadingProgressBar(renderer: renderer)
        }
        .onChange(of: searchText) { _, newValue in
            // 防抖：连续输入不触发搜索，停顿 250ms 后执行一次（避免大文档全文遍历打满 WebContent）
            searchDebounce?.cancel()
            let item = DispatchWorkItem { renderer.search(newValue) }
            searchDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
        // 窗口标题：显示当前文件名与所在目录 + 字数（无文档时显示 App 名）
        .navigationTitle(doc.url?.lastPathComponent ?? "MDReview")
        .navigationSubtitle(subtitleText)
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
            // 搜索：呼出浮动面板（⌘F；文档有选中文字时预填搜索词）
            Button { toggleSearch() } label: { Label("Search", systemImage: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command)
                .help("Search in Document")
        }
        // 外观切换：单按钮，图标表示点击后切换的方向——当前亮显月亮（点击切暗）、
        // 当前暗显太阳（点击切亮）。手动覆盖时 accent 圆高亮。
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
            .help(isDarkEffective ? "Switch to Light" : "Switch to Dark")
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
    /// 外观按钮图标：当前亮 → 月亮（点击切暗），当前暗 → 太阳（点击切亮）。
    private var appearanceIconName: String { isDarkEffective ? "sun.max" : "moon" }

    private func renderCurrent() {
        guard let url = doc.url else { return }
        // 整体重载页面（render 内部已重置 pageLoaded），高亮随之清空，故直接复位计数即可。
        // 注意：不要在 loadHTMLString 完成前调用 evaluateJavaScript，
        // 否则页面未就绪会触发 "Request to run JavaScript failed" 持续报错。
        renderer.searchCount = 0
        renderer.searchCurrent = 0
        renderer.readingProgress = 0
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
                await MainActor.run { presentExportSuccess(dest) }
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
                await MainActor.run { presentExportSuccess(dest) }
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

    /// 导出成功反馈：确认 + 可"在 Finder 中显示"。
    private func presentExportSuccess(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Export Complete"
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 用外部编辑器打开当前文件：优先 Cursor / VSCode，未检测到则退回系统默认关联应用。
    private func openInExternalEditor() {
        guard let url = doc.url else { return }
        DocState.shared.openInExternalEditor(url)
    }
}

/// 无文档时的空状态引导页：图标 + 说明 + 主操作按钮，克制不喧宾夺主。
struct EmptyStateView: View {
    let onOpen: () -> Void

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
            Button(action: onOpen) {
                Label("Open…", systemImage: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            Text("Toolbar  Open  ·  Drag & Drop  ·  Recent")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 记忆窗口位置/大小：AppKit 的 frame autosave（跨启动恢复）。
private struct WindowFrameAutosave: NSViewRepresentable {
    static let name = "MDReviewMainWindow"

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.setFrameAutosaveName(Self.name) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 阅读进度条：独立 @ObservedObject 观察 renderer——ContentView 不观察 renderer
/// （避免滚动高频重算整树），进度变化只重绘这一条。
private struct ReadingProgressBar: View {
    @ObservedObject var renderer: MarkdownRenderer

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geo.size.width * renderer.readingProgress, height: 2)
        }
        .allowsHitTesting(false)
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
/// 布局开销极高。
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

/// 系统级高斯模糊背景：NSVisualEffectView 包装。material 可选（popover=强模糊浅色、
/// hudWindow=Spotlight 级深色），state active + behindWindow 模糊面板背后的窗口内容，
/// 比 SwiftUI material 模糊更彻底，适合浮动卡片/搜索框。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
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
        // 高度自适应：面板高度 = 按钮背景高度（可能 28~56 不等），
        // 行内容垂直居中于面板内，矮面板也不会被裁剪。
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onExitCommand { onClose() }   // Esc 关闭搜索面板
                .onKeyPress(keys: [.return]) { press in
                    // Enter 下一个匹配、Shift+Enter 上一个（主流查找栏惯例）
                    if press.modifiers.contains(.shift) { renderer.searchPrev() }
                    else { renderer.searchNext() }
                    return .handled
                }
                .onAppear {
                    // 延迟聚焦：等待浮动面板成为 key window 后输入框才可聚焦
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFocused = true }
                }
            if renderer.searchCount > 0 {
                Text("\(renderer.searchCurrent)/\(renderer.searchCount)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !text.isEmpty {
                // 无匹配时明确提示 0 结果
                Text("0 results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // 箭头按钮：label 撑大固定 frame + contentShape，26x26 可点区域（图标居中）。
            Button { renderer.searchPrev() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(renderer.searchCount == 0)
            Button { renderer.searchNext() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(renderer.searchCount == 0)
            Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 完全高斯模糊：NSVisualEffectView（popover 材质，系统级高强度模糊），
        // 比 SwiftUI material 更彻底——呼出后搜索框与背后内容明显分离
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                // dark 下描边更亮（0.24），避免与模糊背景融为一体
                .stroke(scheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.25), radius: 22, y: 10)
    }
}
