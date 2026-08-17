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
        withAnimation { doc.showSource.toggle() }
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
                SourceView(text: doc.rawText,
                           renderer: renderer,
                           docName: doc.url?.lastPathComponent)
            }
        }
        .contextMenu {
            Button("Copy") { copySelection() }
            if doc.url != nil {
                Button(doc.showSource ? "View Rendered" : "View Source") {
                    toggleSource()
                }
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
            let item = DispatchWorkItem { searchCurrent(newValue) }
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
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search in Document")
            }
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
            .help(doc.showSource ? "Show Rendered" : "Show Source")
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
        renderer.updateRenderedScrollOffset(0)
        renderedProgress = 0
        renderedActiveHeadingID = nil
        renderedScrollOffset = 0
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
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(0, geo.size.width * renderer.readingProgress), height: 3)
                .shadow(color: Color.accentColor.opacity(0.25), radius: 2, y: 1)
                .animation(.easeOut(duration: 0.12), value: renderer.readingProgress)
        }
        .frame(height: 3)
        .allowsHitTesting(false)
    }
}

/// 导出成功弹窗：图标/文字/按钮全部横向居中（替代 NSAlert 的左图标右文字布局）。
private struct ExportSuccessPanel: View {
    let fileName: String
    let onShowInFinder: () -> Void
    let onOK: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 16)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text("Export Complete")
                .font(.title3)
                .fontWeight(.semibold)
            Text(fileName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button("Show in Finder", action: onShowInFinder)
                    .keyboardShortcut(.defaultAction)
                Button("OK", action: onOK)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let renderer: MarkdownRenderer
    let docName: String?

    var body: some View {
        SourceTextView(text: text, renderer: renderer, docName: docName)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// NSTextView 的 SwiftUI 包装：可滚动、可选中、等宽字体；
/// 独立维护源码视图的滚动进度、outline 同步和滚动位置记忆。
struct SourceTextView: NSViewRepresentable {
    let text: String
    let renderer: MarkdownRenderer
    let docName: String?

    func makeCoordinator() -> SourceTextCoordinator {
        SourceTextCoordinator(renderer: renderer, docName: docName)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(scroll: scroll, text: text, docName: docName)
    }
}

@MainActor
final class SourceTextCoordinator: NSObject {
    private let renderer: MarkdownRenderer
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var docName: String?
    private var currentText = ""
    private var headings: [(id: String, range: NSRange)] = []
    private var headingY: [String: CGFloat] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var lastSaveTime: TimeInterval = 0
    private var programmaticActiveUntil: TimeInterval = 0
    private var restored = false
    private var searchTerm = ""
    private var searchRanges: [NSRange] = []
    private var searchIndex = -1

    init(renderer: MarkdownRenderer, docName: String?) {
        self.renderer = renderer
        self.docName = docName
        super.init()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 28, height: 28)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        scroll.documentView = tv

        scrollView = scroll
        textView = tv
        scroll.contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: scroll.contentView,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScroll() }
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
        return scroll
    }

    func update(scroll: NSScrollView, text: String, docName: String?) {
        guard textView != nil else { return }
        let docChanged = docName != self.docName
        self.docName = docName
        if text != currentText {
            currentText = text
            textView?.string = text
            rebuildHeadings()
            if !searchTerm.isEmpty { search(searchTerm) }
        }
        if docChanged || !restored {
            restored = true
            restoreScroll()
        }
    }

    private func rebuildHeadings() {
        guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
        layout.ensureLayout(for: container)
        headings = Self.parseHeadings(currentText)
        headingY.removeAll()
        for h in headings {
            let glyphRange = layout.glyphRange(forCharacterRange: h.range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
            let rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            headingY[h.id] = rect.minY
        }
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
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 20)))
        scroll.reflectScrolledClipView(scroll.contentView)
        handleScroll()
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
            let midY = visible.minY + 20
            var active = headings.first?.id
            for h in headings {
                if let y = headingY[h.id], y <= midY { active = h.id }
            }
            if let active, active != renderer.activeHeadingID {
                renderer.activeHeadingID = active
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
