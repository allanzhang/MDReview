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
    @State private var searchFocusSignal = UUID()
    @State private var isSearchVisible = false
    /// 搜索防抖（大文档 TreeWalker 全文遍历昂贵，输入停顿 250ms 才执行）。
    @State private var searchDebounce: DispatchWorkItem?
    /// 拖拽悬停状态（用于高亮反馈）。
    @State private var isDropTargeted = false
    /// 当前文档字数（窗口副标题显示）。
    @State private var wordCount = 0
    /// rendered 视图切换离开时暂存的进度/active 章节，切回时恢复。
    @State private var renderedProgress: Double = 0
    @State private var renderedActiveHeadingID: String?
    @State private var renderedScrollOffset: Double = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $doc.columnVisibility) {
            sidebar
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        // 工具栏不透明实底，去掉半透明玻璃材质：与侧栏实底统一，厚实清晰（Codex 式）
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
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
        // 打开文档与手动刷新后的内容变化都会更新 rawText，统一由此触发渲染（url 变化必伴随 rawText 变化）
        .onChange(of: doc.rawText) { _, _ in
            wordCount = Self.countWords(doc.rawText)
            DispatchQueue.main.async { renderCurrent() }
        }
        // 外观切换：即时注入 JS 生效，不重载页面（保留滚动位置与渲染状态）
        .onChange(of: doc.appearance) { _, mode in renderer.applyAppearance(mode) }
        // 字号缩放：即时改写 CSS 变量生效，不重载页面（渲染重载时由模板烘焙当前缩放）
        .onChange(of: doc.fontSizeScale) { _, s in renderer.applyFontSize(s) }
        // source / rendered 的进度、outline 高亮和滚动记忆分开管理。
        // 离开 rendered 的快照必须在 showSource 改变前抓取（见 toggleSource），
        // onChange 触发时 SourceView 已经写回 renderer，不能在这里回读。
        .onChange(of: doc.showSource) { _, isSource in
            guard !isSource else { return }
            renderer.readingProgress = renderedProgress
            renderer.activeHeadingID = renderedActiveHeadingID
            renderer.restoreRenderedScrollOffset(renderedScrollOffset)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .mdreviewSourceSelection)) { note in
            guard let sel = note.object as? String else { return }
            let t = sel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { searchText = t }
        }
        // 拖入 Markdown：挂在整窗，避免空状态/源码层盖住 WebView 后丢事件
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        // 记忆窗口位置/大小（AppKit frame autosave，跨启动恢复）
        .background(WindowFrameAutosave())
    }

    private func handleMenuAction(_ action: MenuAction) {
        switch action {
        case .openPanel: openPanel()
        case .search: focusSearch()
        case .toggleSidebar:
            doc.columnVisibility = (doc.columnVisibility == .all) ? .detailOnly : .all
        case .toggleSource: toggleSource()
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

    /// 切换源码/渲染前先抓取 rendered 的实时状态。onChange 阶段 SourceView
    /// 已把 source 滚动写进 renderer，不能作为离开 rendered 的快照来源。
    private func toggleSource() {
        if !doc.showSource {
            renderedProgress = renderer.readingProgress
            renderedActiveHeadingID = renderer.activeHeadingID
            renderedScrollOffset = renderer.renderedScrollOffset
        }
        // 不做淡入淡出动画：动画期间会持续触发布局/绘制，放大大文档的切换卡顿。
        doc.showSource.toggle()
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
        return wordCount > 0
            ? L10n.format("%@ · %lld words", language: doc.resolvedLanguage, dir, wordCount)
            : dir
    }

    /// ⌘F 聚焦工具栏原生搜索框；若文档有选中文字则预填搜索词。
    private func focusSearch() {
        isSearchVisible = true
        searchFocusSignal = UUID()
        if doc.showSource {
            NotificationCenter.default.post(name: .mdreviewSourceGetSelection, object: nil)
        } else {
            renderer.selectedText { sel in
                let t = sel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { self.searchText = t }
            }
        }
    }

    private func toggleSearch() {
        if isSearchVisible {
            isSearchVisible = false
            searchText = ""
            searchCurrent("")
        } else {
            focusSearch()
        }
    }

    private func searchCurrent(_ term: String) {
        if doc.showSource {
            NotificationCenter.default.post(name: .mdreviewSourceSearch, object: term)
        } else {
            renderer.search(term)
        }
    }

    private func searchNext() {
        if doc.showSource {
            NotificationCenter.default.post(name: .mdreviewSourceSearchNext, object: nil)
        } else {
            renderer.searchNext()
        }
    }

    private func searchPrev() {
        if doc.showSource {
            NotificationCenter.default.post(name: .mdreviewSourceSearchPrev, object: nil)
        } else {
            renderer.searchPrev()
        }
    }

    private func copySelection() {
        // 右键菜单是挂在 ZStack 上的 SwiftUI .contextMenu，动作执行时响应链起点已不是
        // NSTextView，sendAction(to: nil) 找不到 copy: 的接收者 —— 表现为「复制没反应」。
        // 源码态改为直发通知、显式指定目标文本视图，不经响应链；渲染态维持原路径。
        if doc.showSource {
            NotificationCenter.default.post(name: .mdreviewSourceCopy, object: nil)
        } else {
            NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
        }
    }

    private func revealInFinder() {
        guard let url = doc.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 侧栏面板底色：浅色下是比内容区更灰一档的面板色（Codex 式分栏），深色沿用系统色。
    private var sidebarPanelColor: Color {
        systemScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 242 / 255, green: 242 / 255, blue: 243 / 255)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // 视图切换：中性灰轨道 + 实底滑块（无 accent 蓝），与大纲灰底选中同一语言
            SidebarSwitcher(showOutline: $doc.showOutline)
                .padding(.horizontal, 8)
                .padding(.top, 8)
            if doc.showOutline {
                OutlineView(renderer: renderer)
            } else {
                RecentView()
            }
        }
        // 系统默认 sidebar toggle 不用；侧栏操作留在 Content Panel 工具栏。
        .toolbar(removing: .sidebarToggle)
        // 侧栏最小宽度：防 Outline/History 按钮文字换行（拉到最窄也不难看）
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        // 侧栏用不透明实底：浅色下用显式浅灰面板色（系统 windowBackgroundColor 在当前系统为纯白，
        // 与内容区无法区分）；深色沿用系统 windowBackgroundColor。
        .background(sidebarPanelColor)
        // macOS 27 起系统分栏分隔不再稳定可见，显式补回侧栏边界。
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(systemScheme == .dark ? 0.10 : 0.12))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack(alignment: .top) {
            // WebView 始终保留实例（NSViewRepresentable 首次 make 后复用），空状态覆盖其上
            ReaderWebView(renderer: renderer)
                // 源码视图常驻但挂在 WebView 的 overlay：隐藏时仍不卸载，
                // 同时不作为 ZStack 的独立尺寸来源向窗口上报 intrinsic/ideal size。
                .overlay {
                    if doc.url != nil {
                        SourceView(text: doc.rawText,
                                   renderer: renderer,
                                   docName: doc.url?.lastPathComponent,
                                   appearance: doc.appearance)
                            .frame(minWidth: 0,
                                   maxWidth: .infinity,
                                   minHeight: 0,
                                   maxHeight: .infinity)
                            .opacity(doc.showSource ? 1 : 0)
                            .allowsHitTesting(doc.showSource)
                    }
                }
            // 无文档空状态引导
            if doc.url == nil {
                EmptyStateView(onOpen: { openPanel() })
            }
            // "大纲思写"加载骨架：盖在最上层，渲染完成整体淡出（正文已在底下）
            OutlineLoadingHost(renderer: renderer, text: doc.rawText)
        }
        .contextMenu {
            Button(L10n.string("Copy", language: doc.resolvedLanguage)) { copySelection() }
            if doc.url != nil {
                Button(L10n.string(doc.showSource ? "View Rendered" : "View Source", language: doc.resolvedLanguage)) {
                    toggleSource()
                }
                Divider()
                Button(L10n.string("Reveal in Finder", language: doc.resolvedLanguage)) { revealInFinder() }
                Button(L10n.string("Open in External Editor", language: doc.resolvedLanguage)) { openInExternalEditor() }
                Divider()
                Button(L10n.string("Export as HTML…", language: doc.resolvedLanguage)) { exportHTML() }
                Button(L10n.string("Export as PDF…", language: doc.resolvedLanguage)) { exportPDF() }
            }
        }
        .overlay(alignment: .topLeading) {
            // 阅读进度条：独立子视图观察 renderer，进度变化时精准重绘
            ReadingProgressBar(renderer: renderer, isDark: isDarkEffective)
        }
        // 字号悬浮控件：渲染态（有文档且非源码）显示在正文右上角
        .overlay(alignment: .topTrailing) {
            if doc.url != nil && !doc.showSource {
                FontSizeControls(scale: $doc.fontSizeScale)
            }
        }
        .onChange(of: searchText) { _, newValue in
            // 防抖：连续输入不触发搜索，停顿 250ms 后执行一次（避免大文档全文遍历打满 WebContent）
            searchDebounce?.cancel()
            let item = DispatchWorkItem { searchCurrent(newValue) }
            searchDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
        // 窗口标题：显示当前文件名与所在目录 + 字数（无文档时显示 App 名）
        .navigationTitle(doc.url?.lastPathComponent ?? L10n.string("MDReview", language: doc.resolvedLanguage))
        .navigationSubtitle(subtitleText)
        // 侧栏切换、打开文件与文档操作统一放在 Content Panel 工具栏。
        .toolbar { detailToolbar }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                // 无动画直接切换：NavigationSplitView 列动画会驱动 detail 区 WKWebView 连续 resize 重排，长文档下明显卡顿
                doc.columnVisibility = (doc.columnVisibility == .all) ? .detailOnly : .all
            } label: {
                Label(L10n.string("Sidebar", language: doc.resolvedLanguage),
                      systemImage: doc.columnVisibility == .all ? "sidebar.left" : "sidebar.right")
            }
            .help(L10n.string(doc.columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar", language: doc.resolvedLanguage))
        }
        ToolbarItem(placement: .navigation) {
            Button { openPanel() } label: {
                Label(L10n.string("Open", language: doc.resolvedLanguage), systemImage: "folder")
            }
            .help(L10n.string("Open Markdown File", language: doc.resolvedLanguage))
        }
        ToolbarItem(placement: .primaryAction) {
            if isSearchVisible {
                SearchFieldToolbarItem(renderer: renderer,
                                       text: $searchText,
                                       focusSignal: $searchFocusSignal,
                                       searchNext: { searchNext() },
                                       searchPrev: { searchPrev() },
                                       onCancel: { toggleSearch() })
            } else {
                Button {
                    toggleSearch()
                } label: {
                    Label(L10n.string("Search", language: doc.resolvedLanguage), systemImage: "magnifyingglass")
                }
                .help(L10n.string("Search in Document", language: doc.resolvedLanguage))
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                refreshDocument()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.clockwise")
                    if doc.hasPendingFileUpdate {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -3)
                    }
                }
            }
            .help(L10n.string("Reload from Disk", language: doc.resolvedLanguage))
            .disabled(doc.url == nil)
        }
        ToolbarItem(placement: .automatic) {
            Button {
                toggleSource()
            } label: {
                Image(systemName: doc.showSource ? "doc.richtext" : "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(doc.showSource ? Color.white : Color.primary)
                    .padding(6)
                    .background {
                        if doc.showSource {
                            Circle().fill(Color.accentColor)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(doc.showSource ? "Show Rendered" : "Show Source", language: doc.resolvedLanguage))
            .disabled(doc.url == nil)
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
            .help(L10n.string(isDarkEffective ? "Switch to Light" : "Switch to Dark", language: doc.resolvedLanguage))
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Button(L10n.string("Export as HTML…", language: doc.resolvedLanguage)) { exportHTML() }
                Button(L10n.string("Export as PDF…", language: doc.resolvedLanguage)) { exportPDF() }
            } label: {
                Label(L10n.string("Export", language: doc.resolvedLanguage), systemImage: "square.and.arrow.up")
            }
            .help(L10n.string("Export Document", language: doc.resolvedLanguage))
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
        renderer.updateRenderedScrollOffset(0)
        renderedProgress = 0
        renderedActiveHeadingID = nil
        renderedScrollOffset = 0
        searchText = ""
        renderer.render(doc.rawText, baseURL: url.deletingLastPathComponent(),
                        docName: url.lastPathComponent, appearance: doc.appearance, fontScale: doc.fontSizeScale)
    }

    /// 手动刷新：重新读盘并重渲染。内容有变化时更新 rawText（由 onChange 统一触发渲染）；
    /// 内容未变化时保持当前内容，仅强制重渲染；读取失败则保留更新红点。
    private func refreshDocument() {
        guard let url = doc.url else { return }
        Task {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text != doc.rawText {
                    doc.rawText = text
                } else {
                    renderCurrent()
                }
                doc.clearPendingFileUpdate()
            } catch {
                // 读盘失败时保留红点，等待用户重试。
            }
        }
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
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = MarkdownFileDrop.url(fromLoadedItem: item) else { return }
                    DispatchQueue.main.async { DocState.shared.open(url) }
                }
                continue
            }
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    guard let url = object as? URL, MarkdownFileDrop.isMarkdown(url) else { return }
                    DispatchQueue.main.async { DocState.shared.open(url) }
                }
            }
        }
        return accepted
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
        alert.messageText = L10n.string("Export Failed", language: doc.resolvedLanguage)
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// 导出成功反馈：居中对齐的确认弹窗（NSAlert 布局是图标左/文字右，无法居中）。
    private func presentExportSuccess(_ url: URL) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        let view = ExportSuccessPanel(
            fileName: url.lastPathComponent,
            language: doc.resolvedLanguage,
            onShowInFinder: { NSApp.stopModal(withCode: .alertFirstButtonReturn) },
            onOK: { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(NSSize(width: 340, height: 200))
        // 相对主窗口居中（而非屏幕居中）
        if let win = NSApp.mainWindow {
            panel.setFrameOrigin(NSPoint(
                x: win.frame.midX - panel.frame.width / 2,
                y: win.frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        if response == .alertFirstButtonReturn {
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
    @EnvironmentObject private var doc: DocState
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(L10n.string("MDReview", language: doc.resolvedLanguage))
                .font(.title2)
                .fontWeight(.medium)
            Text(L10n.string("Open a Markdown file or drop one here", language: doc.resolvedLanguage))
                .foregroundStyle(.secondary)
            Button(action: onOpen) {
                Label(L10n.string("Open…", language: doc.resolvedLanguage), systemImage: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            Text(L10n.string("Toolbar  Open  ·  Drag & Drop  ·  Recent", language: doc.resolvedLanguage))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 记忆主窗口位置/大小：AppKit 的 frame autosave（跨启动恢复）。
private final class WindowFrameAutosaveView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.setFrameAutosaveName(MainWindow.autosaveName)
    }
}

private struct WindowFrameAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowFrameAutosaveView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 阅读进度条：独立 @ObservedObject 观察 renderer——ContentView 不观察 renderer
/// （避免滚动高频重算整树），进度变化只重绘这一条。
private struct ReadingProgressBar: View {
    @ObservedObject var renderer: MarkdownRenderer
    let isDark: Bool

    /// 中性灰进度条：无渐变无光晕，贴合原生质感。浅色 #c5cad3 / 深色 #525252，
    /// 在各自页面底色（#ffffff / #262626）上可见但不抢眼。
    private var barColor: Color {
        isDark ? Color(red: 82/255, green: 82/255, blue: 82/255)
               : Color(red: 197/255, green: 202/255, blue: 211/255)
    }

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(barColor)
                .frame(width: max(0, geo.size.width * renderer.readingProgress), height: 2)
                .animation(.easeOut(duration: 0.12), value: renderer.readingProgress)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// 观察 renderer.isLoading 的宿主：ContentView 不观察 renderer（避免整树重算），
/// 与 ReadingProgressBar 同一模式；loading 期间展示"大纲思写"骨架。
private struct OutlineLoadingHost: View {
    @ObservedObject var renderer: MarkdownRenderer
    let text: String

    var body: some View {
        if renderer.isLoading {
            OutlineLoadingView(text: text)
                .transition(.opacity)
        }
    }
}

/// "大纲思写"加载骨架：WebView 解析/渲染 MD 期间，把预扫描的文档标题逐条淡入（前 14 条），
/// 顶部 2pt 扫描线往返扫动示意解析中（JS 渲染是同步爆发、无真实进度可报）。
/// 完成即整体淡出，底下正文已渲染完成；与正文区同底色，出现/消失无白闪。
private struct OutlineLoadingView: View {
    private static let maxShown = 14
    private let headings: [(level: Int, text: String)]

    @State private var showCount = 0
    @State private var scanningOffset: CGFloat = 0
    @Environment(\.colorScheme) private var scheme

    init(text: String) {
        headings = Self.scanHeadings(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            scanningLine
                .padding(.bottom, 6)
            ForEach(Array(headings.prefix(Self.maxShown).enumerated()), id: \.offset) { index, h in
                Text(h.text)
                    .font(.system(size: h.level == 1 ? 13 : 11.5,
                                  weight: h.level == 1 ? .semibold : .regular))
                    .foregroundStyle(h.level == 1 ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, h.level > 1 ? 12 : 0)
                    .opacity(index < showCount ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showCount)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if headings.count > Self.maxShown {
                Text("…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .opacity(showCount >= Self.maxShown ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showCount)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: startReveal)
    }

    /// 扫描线：与阅读进度条同色的 2pt 短段左右往返扫动。
    private var scanningLine: some View {
        GeometryReader { geo in
            Capsule()
                .fill(scheme == .dark
                      ? Color(red: 82/255, green: 82/255, blue: 82/255)
                      : Color(red: 197/255, green: 202/255, blue: 211/255))
                .frame(width: geo.size.width * 0.25, height: 2)
                .offset(x: scanningOffset * geo.size.width * 0.75)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: true)) {
                        scanningOffset = 1
                    }
                }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private func startReveal() {
        let total = min(headings.count, Self.maxShown)
        guard total > 0 else { return }
        Task { @MainActor in
            for i in 1...total {
                try? await Task.sleep(for: .milliseconds(45))
                showCount = i
            }
        }
    }

    /// 预扫描文档标题（跳过代码围栏），只取层级与文本——骨架就是文档自己的大纲。
    private static func scanHeadings(_ text: String) -> [(level: Int, text: String)] {
        var result: [(level: Int, text: String)] = []
        var inFence = false
        text.enumerateLines { line, _ in
            if line.range(of: "^\\s*```", options: .regularExpression) != nil { inFence.toggle() }
            guard !inFence,
                  let m = line.range(of: "^#{1,6}\\s+", options: .regularExpression) else { return }
            let level = line.distance(from: m.lowerBound, to: m.upperBound) - 1
            let body = line[m.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return }
            result.append((level, body))
        }
        return result
    }
}

/// 字号悬浮控件（上 A− / 下 A+ 竖排）：缩放 0.8×~1.5×、步进 0.15（单击 ~15%，肉眼可辨），经 renderer.applyFontSize 即时生效。
/// 中性灰胶囊底（与 SidebarSwitcher 同一语言），轻阴影托起悬浮感。
private struct FontSizeControls: View {
    @Binding var scale: Double
    @EnvironmentObject private var doc: DocState
    @Environment(\.colorScheme) private var scheme

    private static let minScale = 0.8
    private static let maxScale = 1.5
    private static let step = 0.15

    var body: some View {
        VStack(spacing: 0) {
            FontSizeButton("A−", hint: L10n.string("Decrease Font Size", language: doc.resolvedLanguage), enabled: scale > Self.minScale) {
                scale = min(Self.maxScale, max(Self.minScale, scale - Self.step))
            }
            Divider().frame(width: 14)
            FontSizeButton("A+", hint: L10n.string("Increase Font Size", language: doc.resolvedLanguage), enabled: scale < Self.maxScale) {
                scale = min(Self.maxScale, max(Self.minScale, scale + Self.step))
            }
        }
        .padding(3)
        .background {
            Capsule().fill(scheme == .dark ? Color(white: 0.26) : Color.white)
                .overlay { Capsule().stroke(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)) }
        }
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.30 : 0.08), radius: 3, y: 1)
        .padding(.top, 8)
        .padding(.trailing, 12)
    }
}

/// 单个字号按钮：hover 出现中性灰圆角底，按下由 FontSizePressStyle 提供缩放+变淡反馈，松开回弹。
private struct FontSizeButton: View {
    let title: String
    let hint: String
    let enabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    init(_ title: String, hint: String, enabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background {
                    if enabled && isHovering {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.09))
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                // onHover 挂在 label 内：挂在 Button 外层时，鼠标移出按钮区域会丢 hover 退出事件，
                // 高亮停在 hover 态，表现为鼠标在标题栏区域移动时"卡住不动"。
                .onHover { isHovering = enabled && $0 }
        }
        .buttonStyle(FontSizePressStyle())
        .disabled(!enabled)
        .help(hint)
    }
}

/// 按下反馈：轻微缩小 + 变淡，松开幅度回弹（纯 plain 按钮在 macOS 上没有默认按压反馈）。
private struct FontSizePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 导出成功弹窗：图标/文字/按钮全部横向居中（替代 NSAlert 的左图标右文字布局）。
private struct ExportSuccessPanel: View {
    let fileName: String
    let language: AppLanguage
    let onShowInFinder: () -> Void
    let onOK: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 16)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text(L10n.string("Export Complete", language: language))
                .font(.title3)
                .fontWeight(.semibold)
            Text(fileName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button(L10n.string("Show in Finder", language: language), action: onShowInFinder)
                    .keyboardShortcut(.defaultAction)
                Button(L10n.string("OK", language: language), action: onOK)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// 源码视图：只读展示当前 Markdown 原文。
/// 用 NSTextView（AppKit 文本系统）承载而非 SwiftUI Text——后者渲染 MB 级大文本时
/// 布局开销极高。
struct SourceView: View {
    let text: String
    let renderer: MarkdownRenderer
    let docName: String?
    let appearance: AppearanceMode

    var body: some View {
        SourceTextView(text: text, renderer: renderer, docName: docName, appearance: appearance)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// NSTextView 的 SwiftUI 包装：可滚动、可选中、等宽字体；
/// 独立维护源码视图的滚动进度、outline 同步和滚动位置记忆。
struct SourceTextView: NSViewRepresentable {
    let text: String
    let renderer: MarkdownRenderer
    let docName: String?
    let appearance: AppearanceMode

    func makeCoordinator() -> SourceTextCoordinator {
        SourceTextCoordinator(renderer: renderer, docName: docName)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(scroll: scroll, text: text, docName: docName, appearance: appearance)
    }
}

/// 主题切换时同步刷新源码文本外观的 NSTextView 子类。
/// 顺带承担当前行高亮：文本视图自己的背景色由 super.draw 填，
/// 高亮只能画在文字之后，用极淡的一层墨色叠在整行宽度上，视觉与垫底等价。
private final class ThemedTextView: NSTextView {
    var appearanceChanged: (() -> Void)?

    /// 选区覆盖行的整行高亮矩形（文本视图坐标，nil 表示不高亮）。
    var highlightRect: NSRect? {
        didSet {
            // 只重画新旧高亮的并集，不整屏重画。
            let previous = oldValue ?? .zero
            let current = highlightRect ?? .zero
            var dirty = current.isEmpty ? previous : current
            if !previous.isEmpty { dirty = dirty.isEmpty ? previous : dirty.union(previous) }
            if !dirty.isEmpty { setNeedsDisplay(dirty) }
        }
    }
    var highlightColor: NSColor = .clear {
        didSet {
            guard !highlightRectIsEmpty else { return }
            setNeedsDisplay((highlightRect ?? .zero).intersection(bounds))
        }
    }

    private var highlightRectIsEmpty: Bool { (highlightRect ?? .zero).isEmpty }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let rect = highlightRect, !rect.isEmpty else { return }
        let hit = dirtyRect.intersection(rect)
        guard !hit.isEmpty else { return }
        highlightColor.setFill()
        hit.fill()
    }
}

/// 源码行号排版：把布局管理器的行片段翻译成「逻辑行号 + 文本视图坐标矩形」。
/// 行号栏与当前行高亮共用这一份换算，保证两者纵向永远对齐。
@MainActor
enum SourceLineLayout {
    /// 一个行片段：逻辑行号（0 基）、是否为该行的首个片段（软换行的续行为 false）、
    /// 以及片段在文本视图坐标系里的矩形。
    struct Fragment {
        let line: Int
        let isFirstOfLine: Bool
        let rect: NSRect
    }

    /// 容器坐标 → 文本视图坐标：NSTextView 把文本容器按 textContainerInset 摆放，
    /// 实测布局管理器返回的片段矩形加上 inset 即为文本视图坐标。
    private static func toViewRect(_ rect: NSRect, inset: NSSize) -> NSRect {
        rect.offsetBy(dx: inset.width, dy: inset.height)
    }

    /// 遍历 clip（文本视图坐标）纵向范围内的行片段。
    /// 只走可视片段，成本与文档大小无关。
    static func visibleFragments(in tv: NSTextView,
                                 lineIndex: SourceLineIndex,
                                 clip: NSRect) -> [Fragment] {
        guard let layout = tv.layoutManager, let container = tv.textContainer else { return [] }
        let inset = tv.textContainerInset
        // 查询矩形必须横向覆盖正文：行号栏自身的 x 范围换算到容器坐标后落在正文左侧，
        // 直接用它查询会得到空区间，行号一个都不画。纵向按调用方给的 clip 收窄。
        let query = NSRect(x: 0,
                           y: clip.minY - inset.height,
                           width: container.size.width,
                           height: clip.height)
        return fragments(layout: layout,
                         container: container,
                         inset: inset,
                         lineIndex: lineIndex,
                         glyphRange: layout.glyphRange(forBoundingRect: query, in: container),
                         textLength: currentTextLength(of: tv))
    }

    /// 选区覆盖的行在文本视图坐标里的整行高亮矩形（含软换行占的所有片段高度）。
    /// 连续行之间没有空隙，所以一个包围盒就够，不必逐行拼。
    static func highlightRect(forCharacterRange range: NSRange,
                              in tv: NSTextView,
                              lineIndex: SourceLineIndex) -> NSRect? {
        guard range.length > 0,
              let layout = tv.layoutManager,
              let container = tv.textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let box = toViewRect(layout.boundingRect(forGlyphRange: glyphs, in: container),
                             inset: tv.textContainerInset)
        guard !box.isEmpty else { return nil }
        return NSRect(x: 0, y: box.minY, width: tv.bounds.width, height: box.height)
    }

    private static func fragments(layout: NSLayoutManager,
                                  container: NSTextContainer,
                                  inset: NSSize,
                                  lineIndex: SourceLineIndex,
                                  glyphRange: NSRange,
                                  textLength: Int) -> [Fragment] {
        guard textLength > 0 else { return [] }
        var result: [Fragment] = []
        var glyph = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while glyph < end {
            var effective = NSRange()
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &effective)
            let character = layout.characterIndexForGlyph(at: glyph)
            // 文末换行之后 NSTextView 仍有一个空片段，它不对应真实行，跳过。
            guard character < textLength else { break }
            let line = lineIndex.line(ofCharacter: character)
            result.append(Fragment(line: line,
                                   isFirstOfLine: character == lineIndex.start(ofLine: line),
                                   rect: toViewRect(used, inset: inset)))
            glyph = NSMaxRange(effective)
        }
        return result
    }

    private static func currentTextLength(of tv: NSTextView) -> Int {
        (tv.string as NSString).length
    }
}

/// 源码视图行号栏：作为文本视图的子视图固定在左侧，随内容滚动而无需重绘。
/// 视觉沿用渲染端代码块行号栏（reader.css 的 .code-gutter）：等宽、右对齐、灰色、不可选中。
final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    var lineIndex = SourceLineIndex("")
    /// 当前行行号（0 基），nil 表示无当前行。
    var activeLine: Int? {
        didSet {
            guard activeLine != oldValue else { return }
            invalidateVisible()
        }
    }
    var numberColor: NSColor = .secondaryLabelColor {
        didSet { invalidateVisible() }
    }
    var activeNumberColor: NSColor = .labelColor {
        didSet { invalidateVisible() }
    }
    var numberFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { invalidateVisible() }
    }

    /// 只把当前屏幕可见的行号区域标脏；文本视图尚未挂载时退回整视图。
    func invalidateVisible() {
        guard let tv = textView else {
            needsDisplay = true
            return
        }
        let visible = bounds.intersection(convert(tv.visibleRect, from: tv))
        // 尚未形成可见区时不回退整栏标脏：后续滚入或 frame 变化会自然触发重绘。
        guard !visible.isEmpty else { return }
        setNeedsDisplay(visible)
    }

    /// 数字左边距：源码视图外框到首位数字的留白，避免行号贴边。
    static let leftPad: CGFloat = 12
    /// 数字右边距：末位数字到行号栏右缘。
    static let numberRightPad: CGFloat = 6
    /// 行号栏右缘到正文起始的间距。
    static let textGap: CGFloat = 12

    /// 行号栏宽度：位数决定，= 左边距 + 数字总宽 + 数字右边距。
    static func width(forLineCount count: Int, font: NSFont) -> CGFloat {
        let digits = max(2, String(count).count)
        let digitWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        return ceil(CGFloat(digits) * digitWidth) + leftPad + numberRightPad
    }

    // 与文本视图同为 flipped，绘制时直接使用布局矩形坐标。
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// 不接管命中测试：点行号仍要能选中文本。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, bounds.width > 0 else { return }
        // dirtyRect 可能是整篇文档高度（needsDisplay=true 时），必须再与文本视图
        // 当前可见区域求交集，否则行号栏会遍历并绘制全部行，切源码时造成卡顿。
        let clip = dirtyRect.intersection(bounds).intersection(convert(tv.visibleRect, from: tv))
        guard !clip.isEmpty else { return }
        // 先填底再画：本视图非 opaque，原先直接画数字，旧数字没有任何东西盖掉。
        // 拖动窗口重排时新数字画在新位置、旧数字留在原位 —— 表现为行号重影且位置不动，
        // 松手触发整窗重绘才恢复正常。底色取正文文本视图的背景色，视觉上无缝。
        tv.backgroundColor.setFill()
        clip.fill()
        for fragment in SourceLineLayout.visibleFragments(in: tv, lineIndex: lineIndex, clip: clip)
        where fragment.isFirstOfLine {
            // 软换行的续行留空：同一逻辑行只在首个片段上标号。
            let color = fragment.line == activeLine ? activeNumberColor : numberColor
            let label = NSAttributedString(string: String(fragment.line + 1),
                                           attributes: [.font: numberFont, .foregroundColor: color])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - LineNumberGutterView.numberRightPad - size.width,
                                   y: fragment.rect.minY + (fragment.rect.height - size.height) / 2))
        }
    }
}

@MainActor
final class SourceTextCoordinator: NSObject, NSTextViewDelegate {
    private let renderer: MarkdownRenderer
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var gutter: LineNumberGutterView?
    private var docName: String?
    private var currentText = ""
    private var lineIndex = SourceLineIndex("")
    private var headings: [(id: String, range: NSRange)] = []
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var lastSaveTime: TimeInterval = 0
    private var programmaticActiveUntil: TimeInterval = 0
    private var restored = false
    private var searchTerm = ""
    /// 上次已应用的暗色状态；用于避免 SwiftUI 反复 update 时重写整篇文本和全 bounds 标脏。
    private var lastDark: Bool?
    private var searchRanges: [NSRange] = []
    private var searchIndex = -1
    /// 拖动窗口宽度时的重排防抖：帧通知只更新几何，停止后再统一改容器宽度。
    /// 仅在主线程读写；标 unsafe 是为了允许 deinit 取消任务（与 observers 同理）。
    nonisolated(unsafe) private var widthRelayoutWorkItem: DispatchWorkItem?
    /// 帧变化后的几何同步任务：帧通知可能在 AppKit 布局阶段同步送达，
    /// 延后一拍再改 gutter/frame/textContainerInset，避免布局重入。
    nonisolated(unsafe) private var frameGeometryWorkItem: DispatchWorkItem?
    /// 选区高亮查询任务：glyph/boundingRect 查询必须跨 run-loop 边界合并执行，
    /// 不得从 updateNSView、frameDidChange 或选区通知中同步触发。
    nonisolated(unsafe) private var selectionHighlightWorkItem: DispatchWorkItem?
    /// 已应用到文本容器的宽度；用于避免重复触发同一宽度的布局失效。
    private var lastTextContainerWidth: CGFloat?
    /// 分片布局任务：任务被取消或代际变化后不得继续推进。
    /// 仅在主线程读写；标 unsafe 是为了允许 deinit 取消任务。
    nonisolated(unsafe) private var progressiveLayoutWorkItem: DispatchWorkItem?
    private var layoutGeneration = 0
    private var layoutCursor = 0
    private var layoutLength = 0

    init(renderer: MarkdownRenderer, docName: String?) {
        self.renderer = renderer
        self.docName = docName
        super.init()
    }

    deinit {
        widthRelayoutWorkItem?.cancel()
        frameGeometryWorkItem?.cancel()
        selectionHighlightWorkItem?.cancel()
        progressiveLayoutWorkItem?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true

        let tv = ThemedTextView()
        tv.appearanceChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: LineNumberGutterView.width(forLineCount: 1, font: tv.font!)
                                            + LineNumberGutterView.textGap,
                                       height: 28)
        // 宽度跟踪关闭：NSTextView 每帧自动改容器宽度会触发整篇重新换行，
        // 窗口拖动时形成 60Hz 的全量布局，是缩放卡顿的主因。
        tv.textContainer?.widthTracksTextView = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = self
        scroll.documentView = tv

        // 行号栏：文本视图子视图，跟随内容滚动，滚动时无需重绘。
        let gutter = LineNumberGutterView(frame: NSRect(x: 0, y: 0, width: 46, height: 1))
        gutter.textView = tv
        gutter.numberFont = tv.font!
        gutter.autoresizingMask = [.width, .height]
        tv.addSubview(gutter)
        self.gutter = gutter

        scrollView = scroll
        textView = tv
        refreshAppearance()
        scroll.contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: scroll.contentView,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScroll() }
        })
        // 宽度变化会改变软换行位置：行号与高亮都要按新排版重画。
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                            object: tv,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFrameChange() }
        })
        observers.append(center.addObserver(forName: .mdreviewSourceScroll,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated {
                self?.scrollToHeading(id)
            }
        })
        observers.append(center.addObserver(forName: .mdreviewSourceSearch,
                                            object: nil,
                                            queue: .main) { [weak self] note in
            let term = note.object as? String ?? ""
            MainActor.assumeIsolated {
                self?.search(term)
            }
        })
        observers.append(center.addObserver(forName: .mdreviewSourceSearchNext,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.searchNext()
            }
        })
        observers.append(center.addObserver(forName: .mdreviewSourceSearchPrev,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.searchPrev()
            }
        })
        observers.append(center.addObserver(forName: .mdreviewSourceGetSelection,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tv = self.textView else {
                    NotificationCenter.default.post(name: .mdreviewSourceSelection, object: "")
                    return
                }
                let range = tv.selectedRange()
                let selection = range.location != NSNotFound
                    ? (tv.string as NSString).substring(with: range)
                    : ""
                NotificationCenter.default.post(name: .mdreviewSourceSelection, object: selection)
            }
        })
        // 右键菜单的 Copy：显式指定目标文本视图，绕开「菜单弹出后响应链起点不是 NSTextView」的问题。
        observers.append(center.addObserver(forName: .mdreviewSourceCopy,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let tv = self?.textView else { return }
                NSApp.sendAction(Selector(("copy:")), to: tv, from: nil)
            }
        })
        return scroll
    }

    func update(scroll: NSScrollView, text: String, docName: String?, appearance: AppearanceMode) {
        guard let tv = textView as? ThemedTextView else { return }
        let docChanged = docName != self.docName
        self.docName = docName
        let textChanged = text != currentText
        if textChanged {
            currentText = text
            lineIndex = SourceLineIndex(text)
            tv.string = text
            // 必须在写入之后同步：文本视图的高度在写入时才最终确定，
            // 行号栏尺寸早一步就会停在旧高度上，导致 draw 拿到空 dirtyRect。
            applyGutterMetrics()
            // 新文本写入后让容器宽度与当前视图对齐；关闭自动跟踪后需显式设置一次。
            if let container = tv.textContainer {
                let width = max(1, tv.bounds.width - 2 * tv.textContainerInset.width)
                container.size.width = width
                lastTextContainerWidth = width
            }
            rebuildHeadings()
            // 首帧只排可见区；完整高度交给分片任务逐步补齐，避免首次切换同步卡住。
            scheduleProgressiveLayout(tv)
            scheduleSelectionHighlight()
            if !searchTerm.isEmpty { search(searchTerm) }
        }
        if docChanged || !restored {
            restored = true
            restoreScroll()
        }
        refreshAppearance(forceTextColor: textChanged)
    }

    /// 选区变化（含点选、拖选、搜索跳转）时刷新当前行高亮与行号强调。
    /// delegate 可能在文本系统布局中同步触发，因此只登记任务，不直接查询 glyph。
    func textViewDidChangeSelection(_ notification: Notification) {
        scheduleSelectionHighlight()
    }

    /// 行号位数随文档行数变化，行号栏宽度与文本左边距一起跟着调整。
    private func applyGutterMetrics() {
        guard textView != nil else { return }
        syncGutterFrame()
        gutter?.lineIndex = lineIndex
        gutter?.invalidateVisible()
    }

    /// 行号栏尺寸必须显式跟着文本视图走：文本视图初始为 0×0，
    /// 只靠 autoresizing 会在赋值 documentView 时序里留下 0 尺寸，
    /// 结果是 draw 拿到空 dirtyRect，一个行号都不画。
    private func syncGutterFrame() {
        guard let tv = textView, let gutter else { return }
        let font = tv.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let width = LineNumberGutterView.width(forLineCount: lineIndex.count, font: font)
        let target = NSRect(x: 0, y: 0, width: width, height: tv.frame.height)
        if gutter.frame != target { gutter.frame = target }
        let inset = NSSize(width: width + LineNumberGutterView.textGap, height: 28)
        if tv.textContainerInset != inset {
            tv.textContainerInset = inset
        }
    }

    /// 跨一个 run-loop 边界后合并执行一次选区高亮，避免多个布局入口重复查询。
    private func scheduleSelectionHighlight() {
        selectionHighlightWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.selectionHighlightWorkItem = nil
            self.updateSelectionHighlight()
        }
        selectionHighlightWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    /// 当前行 = 选区首字符所在行；多行选区整段高亮，行号强调落在首行。
    private func updateSelectionHighlight() {
        guard let tv = textView as? ThemedTextView, let gutter else { return }
        let length = currentText.utf16.count
        guard length > 0 else {
            tv.highlightRect = nil
            gutter.activeLine = nil
            return
        }
        let selection = tv.selectedRange()
        let first = min(max(selection.location, 0), length - 1)
        let last = min(max(NSMaxRange(selection) - 1, first), length - 1)
        let startLine = lineIndex.line(ofCharacter: first)
        let endLine = lineIndex.line(ofCharacter: last)
        gutter.activeLine = startLine
        // 扩到整行：起点取首行行首，终点取下一行行首；已经是最后一行则取文末。
        let rangeStart = lineIndex.start(ofLine: startLine)
        let rangeEnd = endLine + 1 < lineIndex.count ? lineIndex.start(ofLine: endLine + 1) : length
        guard rangeEnd > rangeStart else {
            tv.highlightRect = nil
            return
        }
        tv.highlightRect = SourceLineLayout.highlightRect(
            forCharacterRange: NSRange(location: rangeStart, length: rangeEnd - rangeStart),
            in: tv,
            lineIndex: lineIndex)
    }

    /// 文本视图尺寸变化：高度随文档增长、宽度随窗口变化，
    /// 行号栏尺寸与换行位置都要跟着重算。
    private func handleFrameChange() {
        guard let tv = textView else { return }
        frameGeometryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak tv] in
            guard let self, let tv else { return }
            self.frameGeometryWorkItem = nil
            self.syncGutterFrame()
            self.gutter?.invalidateVisible()
            self.scheduleSelectionHighlight()
            self.scheduleWidthRelayout(tv)
        }
        frameGeometryWorkItem = item
        DispatchQueue.main.async(execute: item)
    }

    /// resize 期间只处理可见几何；停止拖动 140ms 后再更新容器宽度。
    /// 容器宽度改变只失效布局，实际字形按可见区惰性生成，避免整篇同步重排。
    private func scheduleWidthRelayout(_ tv: NSTextView) {
        widthRelayoutWorkItem?.cancel()
        let targetWidth = max(1, tv.bounds.width - 2 * tv.textContainerInset.width)
        guard targetWidth != lastTextContainerWidth else { return }

        let item = DispatchWorkItem { [weak self, weak tv] in
            guard let self, let tv, let container = tv.textContainer else { return }
            self.widthRelayoutWorkItem = nil
            guard container.size.width != targetWidth else {
                self.lastTextContainerWidth = targetWidth
                return
            }
            container.size.width = targetWidth
            self.lastTextContainerWidth = targetWidth
            // 不在这里调用 ensureLayout：下一次可见绘制按需布局，
            // resize 结束后不会再次出现一次全量停顿。
            tv.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length),
                                               actualCharacterRange: nil)
            tv.setNeedsDisplay(tv.visibleRect)
            self.gutter?.invalidateVisible()
            self.scheduleSelectionHighlight()
            // 新宽度下重新从头分片排版；拖动期间不会启动，停止后再跑。
            self.scheduleProgressiveLayout(tv)
        }
        widthRelayoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: item)
    }

    /// 把整篇布局拆成 20k UTF-16 字符的小片，片间让出 run loop。
    /// 20 万行实测：每片平均约 3.35ms、最大约 7.2ms；不再出现 1.2s 的单次阻塞。
    private func scheduleProgressiveLayout(_ tv: NSTextView) {
        progressiveLayoutWorkItem?.cancel()
        layoutGeneration &+= 1
        let generation = layoutGeneration
        layoutCursor = 0
        layoutLength = (tv.string as NSString).length
        guard layoutLength > 0 else { return }
        scheduleProgressiveLayoutChunk(tv, generation: generation)
    }

    private func scheduleProgressiveLayoutChunk(_ tv: NSTextView, generation: Int) {
        guard generation == layoutGeneration else { return }
        let item = DispatchWorkItem { [weak self, weak tv] in
            guard let self,
                  generation == self.layoutGeneration,
                  let tv,
                  let layout = tv.layoutManager else { return }
            self.progressiveLayoutWorkItem = nil
            let start = self.layoutCursor
            guard start < self.layoutLength else { return }
            let end = min(self.layoutLength, start + 20_000)
            layout.ensureLayout(forCharacterRange: NSRange(location: start, length: end - start))
            self.layoutCursor = end
            if end < self.layoutLength {
                self.scheduleProgressiveLayoutChunk(tv, generation: generation)
            } else {
                // 完整布局已到文末；补一次滚动位置，覆盖打开时高度尚不完整的情况。
                self.restoreScroll()
            }
        }
        progressiveLayoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002, execute: item)
    }

    /// 主题切换 / 系统外观变化时刷新源码视图文本与背景。
    /// 外观未变化时直接返回；只有文本内容变化时才重新写入整篇文字颜色。
    private func refreshAppearance(forceTextColor: Bool = false) {
        guard let tv = textView as? ThemedTextView, let scroll = scrollView else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let paletteChanged = lastDark != dark
        guard paletteChanged || forceTextColor else { return }

        let textColor: NSColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.82)
        if paletteChanged {
            let background: NSColor = dark
                ? NSColor(calibratedWhite: 0.149, alpha: 1)
                : NSColor.white
            tv.textColor = textColor
            tv.backgroundColor = background
            scroll.backgroundColor = background
            scroll.drawsBackground = true
            // 行号栏配色沿用渲染端代码块行号栏（reader.css .code-gutter）的克制灰，
            // 当前行用接近正文的颜色保证「哪一行是当前行」一眼可辨。
            gutter?.numberColor = dark
                ? NSColor(calibratedWhite: 0.62, alpha: 0.75)
                : NSColor(calibratedWhite: 0.45, alpha: 0.80)
            gutter?.activeNumberColor = dark
                ? NSColor(calibratedWhite: 0.96, alpha: 1)
                : NSColor(calibratedWhite: 0.05, alpha: 1)
            // 填充色取「文字色的方向」，所以叠在文字上不会洗掉文字：
            // 亮色文字是黑的，所以用黑填充；暗色文字是白的，所以用白填充。
            // 暗色原先用 black 0.22 —— 在 #262626 的暗底上继续压暗，方向反了，等于没有高亮。
            tv.highlightColor = dark
                ? NSColor.white.withAlphaComponent(0.10)
                : NSColor.black.withAlphaComponent(0.12)
        }

        let length = tv.string.utf16.count
        if length > 0 {
            tv.textStorage?.beginEditing()
            tv.textStorage?.addAttribute(.foregroundColor,
                                         value: textColor,
                                         range: NSRange(location: 0, length: length))
            tv.textStorage?.endEditing()
        }
        // 大文档的 bounds 高达数百万点；全 bounds 标脏会随文档高度线性放大。
        // 只标当前可见区，滚入视野的区域由文本存储变更触发正常重绘。
        tv.setNeedsDisplay(tv.visibleRect)
        lastDark = dark
    }

    /// 只解析标题字符范围；标题 Y 坐标依赖排版，延后到真正需要时再计算。
    /// 首次显示源码不再为了大纲状态同步排完整篇 20 万行文档。
    private func rebuildHeadings() {
        headings = Self.parseHeadings(currentText)
    }

    private static func parseHeadings(_ text: String) -> [(id: String, range: NSRange)] {
        let ns = text as NSString
        var result: [(String, NSRange)] = []
        var inFence = false
        var seq = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, lineRange, _, _ in
            let s = line ?? ""
            if s.range(of: "^\\s*```", options: .regularExpression) != nil { inFence.toggle() }
            guard !inFence else { return }
            let match = ns.range(of: "^(#{1,6})\\s+(.+)$", options: .regularExpression, range: lineRange)
            if match.location != NSNotFound {
                result.append(("h-\(seq)", match))
                seq += 1
            }
        }
        return result
    }

    private func restoreScroll() {
        guard let scroll = scrollView, let name = docName,
              let offset = MarkdownRenderer.savedSourceScrollOffset(for: name) else { return }
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        handleScroll()
    }

    /// 用可见区域首字符定位当前标题，不预先排完整篇文档。
    /// 只会触发可见 glyph 查询，避免滚动时对 headingY 做全量坐标扫描。
    private func activeHeading(in visible: NSRect) -> String? {
        guard !headings.isEmpty,
              let tv = textView,
              let layout = tv.layoutManager,
              let container = tv.textContainer else { return nil }
        let inset = tv.textContainerInset
        let query = NSRect(x: 0,
                           y: max(0, visible.minY - inset.height),
                           width: container.size.width,
                           height: max(1, visible.height))
        let glyphs = layout.glyphRange(forBoundingRect: query, in: container)
        guard glyphs.length > 0 else { return headings.first?.id }
        let firstGlyph = glyphs.location
        guard firstGlyph < layout.numberOfGlyphs else { return headings.first?.id }
        let character = layout.characterIndexForGlyph(at: firstGlyph)
        var active: String?
        for h in headings where h.range.location <= character {
            active = h.id
        }
        return active ?? headings.first?.id
    }

    private func scrollToHeading(_ id: String?) {
        guard let id else { return }
        guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer,
              let h = headings.first(where: { $0.id == id }) else { return }
        layout.ensureLayout(for: container)
        let glyphRange = layout.glyphRange(forCharacterRange: h.range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return }
        let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        guard let scroll = scrollView else { return }
        programmaticActiveUntil = Date().timeIntervalSince1970 + 0.4
        let target = NSPoint(x: 0, y: max(0, rect.minY - 20))
        // 大纲点击统一平滑滚动（与渲染视图一致），动画结束再同步 scroller 与高亮
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            scroll.contentView.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                scroll.reflectScrolledClipView(scroll.contentView)
                self?.handleScroll()
            }
        }
    }

    private func search(_ term: String) {
        searchTerm = term
        searchRanges.removeAll()
        searchIndex = -1
        renderer.searchCount = 0
        renderer.searchCurrent = 0
        guard !term.isEmpty, let tv = textView else { return }
        let hay = tv.string as NSString
        var range = NSRange(location: 0, length: hay.length)
        while range.location != NSNotFound && range.length > 0 {
            let found = hay.range(of: term, options: [.caseInsensitive], range: range)
            if found.location == NSNotFound { break }
            searchRanges.append(found)
            let next = NSMaxRange(found)
            range = NSRange(location: next, length: hay.length - next)
        }
        renderer.searchCount = searchRanges.count
        if !searchRanges.isEmpty {
            searchIndex = 0
            showMatch(searchIndex)
        }
    }

    private func searchNext() {
        guard !searchRanges.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchRanges.count
        showMatch(searchIndex)
    }

    private func searchPrev() {
        guard !searchRanges.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchRanges.count) % searchRanges.count
        showMatch(searchIndex)
    }

    private func showMatch(_ index: Int) {
        guard searchRanges.indices.contains(index), let tv = textView, let scroll = scrollView else { return }
        let range = searchRanges[index]
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
        renderer.searchCurrent = index + 1
    }

    private func handleScroll() {
        guard let scroll = scrollView else { return }
        let visible = scroll.contentView.bounds
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - visible.height)
        let progress = maxY > 0 ? min(1, max(0, visible.minY / maxY)) : 0
        renderer.readingProgress = progress

        if Date().timeIntervalSince1970 > programmaticActiveUntil {
            if let active = activeHeading(in: visible) {
                if active != renderer.activeHeadingID {
                    renderer.activeHeadingID = active
                }
            }
        }

        guard docName != nil else { return }
        let now = Date().timeIntervalSince1970
        if now - lastSaveTime > 0.25 {
            lastSaveTime = now
            renderer.saveSourceScrollOffset(visible.minY)
        }
    }
}

/// Outline / Recent 切换器：中性灰轨道 + 实底滑块，不使用 accent 蓝，
/// 与侧栏大纲的灰底选中保持同一克制语言（Codex 式）。
private struct SidebarSwitcher: View {
    @Binding var showOutline: Bool
    @EnvironmentObject private var doc: DocState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            segment(L10n.string("Outline", language: doc.resolvedLanguage), isSelected: showOutline) { showOutline = true }
            segment(L10n.string("Recent", language: doc.resolvedLanguage), isSelected: !showOutline) { showOutline = false }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.06))
        )
    }

    private func segment(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.29) : Color.white)
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.30 : 0.10),
                            radius: 1, x: 0, y: 0.5)
            }
        }
    }
}
