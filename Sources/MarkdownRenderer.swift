import Foundation
import AppKit
import WebKit
import SwiftUI

struct Heading: Identifiable, Hashable, Sendable {
    let id: String
    let level: Int
    let text: String
}

/// 把 JS 回传的 outline 数组安全地转成 [Heading]。模块级非隔离函数，主线程/后台均可调用。
private func parseOutline(_ arr: [[String: Any]]) -> [Heading] {
    arr.compactMap { dict -> Heading? in
        guard let level = dict["level"] as? Int,
              let text = dict["text"] as? String,
              let id = dict["id"] as? String else { return nil }
        return Heading(id: id, level: level, text: text)
    }
}

/// WKWebView 子类：自定义阅读区右键菜单。macOS 的 WKWebView 没有 UIMenu 委托
/// （那是 iOS API），重写 menu(for:)/rightMouseDown 都可能被其内部视图抢先处理——
/// 用本地事件监视器拦截"落在本视图区域内"的 rightMouseDown，弹出自定义菜单。
final class MarkdownWebView: WKWebView {
    private var monitor: Any?

    override init(frame frameRect: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frameRect, configuration: configuration)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let loc = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(loc) else { return event }
            // 弹出我们自己的菜单并消费事件，阻止 WKWebView 内部默认菜单
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: self)
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("Copy", #selector(copySelection(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Toggle Source / Rendered", #selector(toggleSource(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Reveal in Finder", #selector(revealInFinder(_:))))
        menu.addItem(makeItem("Open in External Editor", #selector(openInExternalEditor(_:))))
        menu.addItem(.separator())
        menu.addItem(makeItem("Export as HTML…", #selector(exportHTML(_:))))
        menu.addItem(makeItem("Export as PDF…", #selector(exportPDF(_:))))
        return menu
    }

    private func post(_ action: MenuAction) {
        NotificationCenter.default.post(name: .mdreviewMenuAction, object: action)
    }

    @objc private func copySelection(_ sender: Any?) {
        // 复制选中文字：走系统 copy 响应链（WKWebView 为第一响应者时生效）
        NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
    }
    @objc private func toggleSource(_ sender: Any?) { post(.toggleSource) }
    @objc private func revealInFinder(_ sender: Any?) { post(.revealInFinder) }
    @objc private func openInExternalEditor(_ sender: Any?) { post(.openInExternalEditor) }
    @objc private func exportHTML(_ sender: Any?) { post(.exportHTML) }
    @objc private func exportPDF(_ sender: Any?) { post(.exportPDF) }
}

/// 渲染控制器：持有唯一的 WKWebView，负责加载本地 markdown-it + KaTeX，
/// 把 MD 字符串渲染为 HTML，并通过消息通道取回大纲，提供滚动定位、全文搜索。
///
/// 设计要点：
/// 1. markdown 直接内联进 HTML 一次性 loadHTMLString，避免“先加载空模板再 evaluate 渲染”的脆弱两步时序。
/// 2. 大纲由页面脚本通过 WKScriptMessageHandler 主动 postMessage 回 Swift，比 evaluateJavaScript 更可靠。
/// 3. 仅滚动/搜索使用 evaluateJavaScript，且用 pageLoaded 闸门确保页面已加载完成。
@MainActor final class MarkdownRenderer: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var outline: [Heading] = []
    @Published var searchCount: Int = 0
    @Published var searchCurrent: Int = 0
    /// 页面滚动时由 JS 回传的当前可视章节 id，用于大纲反向高亮（双向同步）。
    @Published var activeHeadingID: String? = nil
    /// 阅读进度 0~1（顶部进度条用），滚动时由 JS 回传。
    @Published var readingProgress: Double = 0
    /// rendered 页面最近一次 JS 回传的精确滚动偏移；切换源码/渲染时用于恢复实际位置。
    private(set) var renderedScrollOffset: Double = 0
    /// 当前文档文件名（阅读进度持久化 key 用，Swift/UserDefaults 侧）。
    private(set) var currentDocName: String?

    /// 标记当前页面导航已完成，未就绪时禁止 evaluateJavaScript。
    private var pageLoaded = false

    override init() {
        // Coordinator 仅在 init 内创建并交给 WKWebView 持有，避免与 renderer 形成强引用环。
        let coord = Coordinator()

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 注册大纲回传通道：页面脚本 window.webkit.messageHandlers.outline.postMessage(...)
        config.userContentController.add(coord, name: "outline")
        // 注册可视章节回传通道：页面滚动时回传当前 heading id，用于大纲反向高亮
        config.userContentController.add(coord, name: "active")
        // 注册阅读进度回传通道：页面滚动时回传 0~1 进度，用于顶部进度条
        config.userContentController.add(coord, name: "progress")

        let wv = MarkdownWebView(frame: .zero, configuration: config)
        wv.autoresizingMask = [.width, .height]
        webView = wv
        super.init()
        coord.renderer = self
        webView.navigationDelegate = coord
    }

    /// 用内联了 markdown 的 HTML 重新加载页面。baseURL 设为 .md 所在目录，使相对图片路径可解析。
    /// docName 为文件名，用于阅读进度记忆（UserDefaults key 区分不同文档，不用 localStorage——
    /// WKWebView 在 file:// baseURL 下 localStorage 不持久，重开文档即丢）。
    func render(_ markdown: String, baseURL: URL?, docName: String? = nil, appearance: AppearanceMode = .system) {
        currentDocName = docName
        pageLoaded = false
        let savedProgress = docName.flatMap { Self.savedProgress(for: $0) }
        webView.loadHTMLString(Self.htmlTemplate(markdown: markdown, docName: docName, savedProgress: savedProgress, chunkMode: "auto", appearance: appearance), baseURL: baseURL)
    }

    // MARK: - 阅读进度持久化（Swift/UserDefaults，可靠跨会话/跨窗口）

    private static let progressKeyPrefix = "mdreview.prog."
    private static let sourceScrollKeyPrefix = "mdreview.sourceScroll."

    /// 当前章节切换（active 消息）时写入 UserDefaults。
    func saveProgress(_ headingID: String) {
        guard let name = currentDocName, !name.isEmpty else { return }
        UserDefaults.standard.set(headingID, forKey: Self.progressKeyPrefix + name)
    }

    /// 打开文档时读取上次阅读位置（章节 id；无记录返回 nil）。
    static func savedProgress(for docName: String) -> String? {
        guard !docName.isEmpty else { return nil }
        return UserDefaults.standard.string(forKey: progressKeyPrefix + docName)
    }

    /// 源码视图独立保存/恢复滚动偏移（与 rendered 的章节记忆分开）。
    func saveSourceScrollOffset(_ offset: CGFloat) {
        guard let name = currentDocName, !name.isEmpty else { return }
        UserDefaults.standard.set(Double(offset), forKey: Self.sourceScrollKeyPrefix + name)
    }

    static func savedSourceScrollOffset(for docName: String) -> CGFloat? {
        guard !docName.isEmpty,
              let stored = UserDefaults.standard.object(forKey: sourceScrollKeyPrefix + docName) as? Double
        else { return nil }
        return CGFloat(stored)
    }

    /// 手动切换外观模式（不重载页面，直接注入 JS 生效，保留滚动位置与渲染状态）。
    func applyAppearance(_ mode: AppearanceMode) {
        guard pageLoaded else { return }
        let script = "window.__forceTheme = '\(mode.rawValue)'; window.applyTheme && window.applyTheme();"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 页面导航完成后回调：兜底再读一次 window.__outline，确保大纲一定能拿到。
    func didFinishNavigation() {
        pageLoaded = true
        webView.evaluateJavaScript("window.__outline") { [weak self] result, _ in
            guard let self else { return }
            if let arr = result as? [[String: Any]] {
                let heads = parseOutline(arr)
                DispatchQueue.main.async {
                    // 判等写入：避免与 postMessage 通道重复赋值触发冗余视图更新
                    guard self.outline != heads else { return }
                    self.outline = heads
                }
            }
        }
    }

    func scrollTo(_ id: String) {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("scrollToHeading(\(Self.jsonString(for: id)))", completionHandler: nil)
    }

    func updateRenderedScrollOffset(_ offset: Double) {
        renderedScrollOffset = offset
    }

    /// 切回 rendered 时把 WebView 滚回离开前的真实位置（仅恢复数值会让进度条/大纲和内容脱节）。
    func restoreRenderedScrollOffset(_ offset: Double) {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("window.scrollTo(0, \(offset))", completionHandler: nil)
    }

    /// 导出当前渲染结果为 PDF（多页，含代码高亮 / KaTeX / 样式，与屏幕渲染一致）。
    /// 基于 WKWebView 原生 createPDF（macOS 11+，completionHandler 版本经 continuation 包装），无额外依赖。
    func exportPDF(to url: URL) async throws {
        guard pageLoaded else { throw ExportError.pageNotLoaded }
        // 分块懒渲染模式下先强制渲染全文，确保 PDF 完整。
        // 注意：__renderAll 必须【同步返回】（不能返回 Promise）——macOS 上
        // evaluateJavaScript 不等待 Promise，会把 Promise 对象当返回值 →
        // "JavaScript execution returned a result of an unsupported type"
        try await evaluateJS("(window.__renderAll ? window.__renderAll() : true)")
        // Mermaid 渲染是异步的（__renderAll 同步返回时图表可能仍在渲染），
        // 必须等图表完成再截图，否则 PDF 里 Mermaid 区域是空白/半成品。
        try await waitForMermaid()
        let config = WKPDFConfiguration()
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let pdfData):
                    continuation.resume(returning: pdfData)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    /// 导出当前渲染结果为【静态 HTML 快照】：从 WebView 取已渲染的正文 DOM（含 KaTeX/高亮/Mermaid
    /// 渲染结果），拼成无 JS 渲染依赖的页面——macOS 预览/QuickLook 与浏览器都能正常打开。
    func exportHTML(to url: URL) async throws {
        guard pageLoaded else { throw ExportError.pageNotLoaded }
        // 1. 确保全文渲染（分块懒渲染模式下补全所有段）
        try await evaluateJS("(window.__renderAll ? window.__renderAll() : true)")
        // 1.5 Mermaid 渲染完成后再抓 DOM（同 exportPDF 的竞态）
        try await waitForMermaid()
        // 1.6 相对图片路径改写为绝对 URL：导出的 HTML 可能保存到 .md 之外的位置，
        // 否则浏览器按导出文件所在目录解析相对路径 → 图片全部失效。
        // im.src（IDL 属性）返回的是相对路径经 baseURL 解析后的绝对 URL，直接取它。
        try await evaluateJS(#"(function(){var imgs=document.querySelectorAll('#content img');for(var i=0;i<imgs.length;i++){var im=imgs[i];var s=im.getAttribute('src')||'';if(s&&!/^(?:https?:|data:|file:|#|\/)/i.test(s)){try{im.setAttribute('src',im.src);}catch(e){}}}})();"#)
        // 1.7 静态 HTML 无 JS 事件绑定，复制按钮会变成死控件，导出前移除
        try await evaluateJS(#"(function(){var bs=document.querySelectorAll('#content .code-copy');for(var i=0;i<bs.length;i++){bs[i].remove();}})();"#)
        // 2. 取渲染后的正文 HTML（String 是 evaluateJavaScript 支持返回类型）
        let innerHTML = try await evaluateJSString("document.getElementById('content').innerHTML")
        // 3. 组装静态页面：内联全部样式，仅留一行主题脚本（Preview 无 JS 时默认亮色，不影响内容）
        let b = Self.bundled
        let style = "<style>\(b.readerCSS)\n\(b.katexCSS)\n\(b.hljsLight)\n\(b.hljsDark)</style>"
        let theme = "<script>try{var m=window.matchMedia('(prefers-color-scheme: dark)').matches;document.documentElement.style.colorScheme=m?'dark':'light';document.body.classList.toggle('theme-dark',m);}catch(e){}</script>"
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(style)</head>
        <body><article id="content">\(innerHTML)</article>\(theme)</body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mermaid 渲染完成等待：evaluateJavaScript 无法等待 Promise，只能轮询
    /// 同步标志 window.__mermaidBusy（__renderMermaid 每提交一个渲染任务 +1，完成 -1），
    /// 归零即全部渲染完成；超时 10s 则放弃等待（避免导出卡死）。
    private func waitForMermaid() async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let busy = try await evaluateJSString("String(window.__mermaidBusy || 0)")
            if busy.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// evaluateJavaScript 的 async 包装（completionHandler → continuation，仅关心执行完成）。
    private func evaluateJS(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// evaluateJavaScript 的 async 包装，返回 String 结果（如 DOM innerHTML）。
    private func evaluateJSString(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let s = result as? String {
                    continuation.resume(returning: s)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    func search(_ term: String) {
        guard pageLoaded else { return }
        let script = "doSearch(\(Self.jsonString(for: term)))"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let count = (result as? Int) ?? 0
            // doSearch 已自动跳到第一个关键字，计数显示 1/N（无结果显示 0）
            DispatchQueue.main.async { self.searchCount = count; self.searchCurrent = count > 0 ? 1 : 0 }
        }
    }

    func searchNext() {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("searchGo(1)") { [weak self] result, _ in
            guard let self else { return }
            if let cur = result as? Int { DispatchQueue.main.async { self.searchCurrent = cur } }
        }
    }

    func searchPrev() {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("searchGo(-1)") { [weak self] result, _ in
            guard let self else { return }
            if let cur = result as? Int { DispatchQueue.main.async { self.searchCurrent = cur } }
        }
    }

    /// 读取文档当前选中文本（⌘F 时用于预填搜索词；无选中/页面未就绪返回空串）。
    func selectedText(completion: @escaping (String) -> Void) {
        guard pageLoaded else { completion(""); return }
        webView.evaluateJavaScript("(window.getSelection ? window.getSelection().toString() : '')") { result, _ in
            DispatchQueue.main.async { completion((result as? String) ?? "") }
        }
    }

    // MARK: - 模板与脚本

    /// 把 Swift 字符串安全转成 JS 字符串字面量（正确转义引号/反斜杠/换行）。
    /// JSON 顶层只接受 array/dictionary，故先包成数组序列化，再去掉首尾方括号。
    /// 额外转义 `</script>` → `<\/script>`：文档内容内联进 <script> 标签时，
    /// 若含该序列会提前闭合脚本标签破坏整个页面（导出 HTML/阅读均受影响）。
    private static func jsonString(for s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        var raw = String(data: data, encoding: .utf8) ?? "[]"
        // HTML 解析器匹配 </script 时大小写不敏感：文档内容里出现 </SCRIPT> / </Script>
        // 同样会提前闭合内联 <script>，必须全部转义。
        raw = raw.replacingOccurrences(of: "</script>", with: "<\\/script>", options: .caseInsensitive)
        return String(raw.dropFirst().dropLast())
    }

    /// 静态资源一次性读取缓存：htmlTemplate 每渲染一次都拼接数 MB 字符串，
    /// 若每次重读 Bundle + 处理字体路径会放大打开文档时的主线程卡顿。
    /// （stored property initializer 不能引用 Self 方法，故读取逻辑直接内联于闭包。）
    /// mermaid.min.js 较大（约 3.5MB），**按需内联**：仅当文档含 mermaid 代码块才注入，普通文档零负担。
    private static let bundled: (readerCSS: String, katexCSS: String, md: String, kx: String, ar: String, footnote: String, hljs: String, hljsLight: String, hljsDark: String, mermaid: String, mdPlugins: String) = {
        let bundle = Bundle.main
        let readerCSS = (try? String(contentsOf: bundle.url(forResource: "reader", withExtension: "css")!)) ?? ""
        var kcss = (try? String(contentsOf: bundle.url(forResource: "katex.min", withExtension: "css")!)) ?? ""
        if let fontBase = bundle.url(forResource: "KaTeX_AMS-Regular", withExtension: "woff2")?
            .deletingLastPathComponent().absoluteString {
            let base = fontBase.hasSuffix("/") ? fontBase : fontBase + "/"
            kcss = kcss.replacingOccurrences(of: "url(fonts/", with: "url(\(base)")
            kcss = kcss.replacingOccurrences(of: "url('fonts/", with: "url('\(base)")
            kcss = kcss.replacingOccurrences(of: "url(\"fonts/", with: "url(\"\(base)")
        }
        return (readerCSS, kcss,
                (try? String(contentsOf: bundle.url(forResource: "markdown-it.min", withExtension: "js")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "katex.min", withExtension: "js")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "katex-auto-render.min", withExtension: "js")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "markdown-it-footnote.min", withExtension: "js")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "highlight.min", withExtension: "js")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "github.min", withExtension: "css")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "github-dark.min", withExtension: "css")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "mermaid.min", withExtension: "js")!)) ?? "",
                (try? String(contentsOf: bundle.url(forResource: "md-plugins.min", withExtension: "js")!)) ?? "")
    }()
    private static let headHTML: String = {
        let b = bundled
        // hljsDark 已 scoped（body.theme-dark 前缀），由 JS 按 class 控制
        return "<style>\(b.readerCSS)\n\(b.katexCSS)\n\(b.hljsLight)\n\(b.hljsDark)</style>"
    }()
    private static let scriptsHTML: String = {
        let b = bundled
        return "<script>\(b.md)</script><script>\(b.kx)</script><script>\(b.ar)</script><script>\(b.footnote)</script><script>\(b.hljs)</script><script>\(b.mdPlugins)</script><script>\(jsFunctions)</script>"
    }()

    /// 把 markdown-it / katex 的 JS、CSS 全部内联进 HTML，避免 file:// 跨源加载问题。
    /// 图片相对路径由 WebView 的 baseURL（.md 目录）解析。
    /// markdown 内容直接内联，页面加载即完成渲染并回传大纲，单次导航更稳健。
    /// internal：导出 HTML 也复用同一模板（自包含、离线可开）。
    /// mermaid 按需：仅当 markdown 含 ```mermaid 代码块才内联约 3.5MB 渲染库，普通文档零负担。
    /// chunkMode：阅读传 "auto"（大文档自动分块懒渲染），导出传 "full"（强制全量保证备份完整）。
    /// appearance：渲染时的外观模式（跟随系统/强制亮/强制暗），导出 HTML 传 .system 跟随打开者系统。
    static func htmlTemplate(markdown: String, docName: String? = nil, savedProgress: String? = nil, chunkMode: String = "auto", appearance: AppearanceMode = .system) -> String {
        let mdJSON = jsonString(for: markdown)
        let renderScript = "<script>\(jsRenderInline(mdJSON: mdJSON, chunkMode: chunkMode))</script>"
        // 正文基准字号跟随系统（body 文本样式，等比放大到阅读尺寸）；导出 HTML 无此变量时 CSS 回退 16px
        let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        let baseSize = max(14.5, bodySize * 1.1)
        let fontVar = "<style>:root { --md-base: \(String(format: "%.1f", baseSize))px; }</style>"
        // 注入文件名供阅读进度记忆使用（UserDefaults key 区分不同文档）
        let docNameScript = "<script>window.__docName = \(jsonString(for: docName ?? ""));</script>"
        // 注入上次阅读位置（章节 id；无则空串），页面渲染完成后 __restoreProgress 使用
        let progressScript = "<script>window.__savedProgress = \(jsonString(for: savedProgress ?? ""));</script>"
        // 注入外观模式供 applyTheme 使用
        let themeScript = "<script>window.__forceTheme = '\(appearance.rawValue)';</script>"
        let mermaidScript = markdown.contains("```mermaid") ? "<script>\(bundled.mermaid)</script>" : ""

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(headHTML)\(fontVar)\(scriptsHTML)\(docNameScript)\(progressScript)\(themeScript)\(mermaidScript)</head>
        <body><article id="content"></article>\(renderScript)</body></html>
        """
    }

    /// 滚动 / 搜索 / 正则转义等工具函数（不含渲染，渲染见 jsRenderInline）。
    /// 使用原始字符串保留正则中的反斜杠。
    private static let jsFunctions = #"""
    // 大纲点击跳转：用瞬时滚动（不用 smooth，避免动画期间持续触发滚动/布局查询）。
    // 分块懒渲染模式下目标标题可能尚未渲染：先渲染到目标所在段再滚动。
    window.scrollToHeading = function(id){
      var e = document.getElementById(id);
      if(!e && window.__sections){
        var n = parseInt(String(id).replace(/^h-/,''), 10);
        if(!isNaN(n)){
          for (var i = 0; i < window.__sections.length; i++){
            var ss = window.__sections[i].startSeq;
            if(ss < 0){ continue; }   // 引言段无标题，跳过（不能 break，否则引言开头的文档跳转失效）
            if(ss <= n){ window.__renderUpToSection(i); }
            else { break; }
          }
          e = document.getElementById(id);
        }
      }
      if(e){ e.scrollIntoView({block:'start'}); }
    };
    // 表格列宽：先按内容 max-content 测出每列理想宽度，再约束到最小/最大
    // 百分比，避免首列过窄或某列独占；最后用 colgroup + fixed 布局落地。
    window.__fitTables = function(root){
      var tables = root.querySelectorAll('table');
      for (var ti = 0; ti < tables.length; ti++){
        var table = tables[ti];
        if (!table.parentNode.classList.contains('md-table-wrap')){
          var wrap = document.createElement('div');
          wrap.className = 'md-table-wrap';
          table.parentNode.insertBefore(wrap, table);
          wrap.appendChild(table);
        }
        if (table.dataset.fitted || table.querySelector('img')) { continue; }
        var rows = table.rows;
        if (!rows.length) { continue; }
        var colCount = rows[0].cells.length;
        if (!colCount) { continue; }
        var hasSpan = false;
        for (var r = 0; r < rows.length; r++){
          var cells = rows[r].cells;
          for (var c = 0; c < cells.length; c++){
            if (cells[c].hasAttribute('colspan') || cells[c].hasAttribute('rowspan')){
              hasSpan = true;
              break;
            }
          }
          if (hasSpan) { break; }
        }
        if (hasSpan) { continue; }
        var clone = table.cloneNode(true);
        clone.style.cssText = 'position:absolute;left:-99999px;top:0;display:table;width:max-content;max-width:none;table-layout:auto;visibility:hidden;';
        var host = document.getElementById('content') || document.body;
        host.appendChild(clone);
        var widths = [];
        for (var c = 0; c < colCount; c++){
          var max = 0;
          for (var r = 0; r < clone.rows.length; r++){
            var cell = clone.rows[r].cells[c];
            if (cell){
              var w = cell.getBoundingClientRect().width;
              if (w > max) { max = w; }
            }
          }
          widths.push(Math.ceil(Math.min(max, 600)));
        }
        host.removeChild(clone);
        var total = 0;
        for (var i = 0; i < widths.length; i++){ total += widths[i]; }
        if (total <= 0) { continue; }
        var available = (table.parentNode && table.parentNode.clientWidth) || host.clientWidth || 780;
        var minPct = Math.min(18, Math.max(12, 120 / available * 100));
        var maxPct = Math.min(60, 100 / widths.length * 2);
        var pcts = [];
        for (var i = 0; i < widths.length; i++){ pcts.push(widths[i] / total * 100); }
        for (var iter = 0; iter < 12; iter++){
          var sum = 0;
          for (var i = 0; i < pcts.length; i++){ sum += pcts[i]; }
          if (sum <= 0) { break; }
          var scale = 100 / sum;
          var changed = false;
          for (var i = 0; i < pcts.length; i++){
            pcts[i] *= scale;
            if (pcts[i] < minPct){ pcts[i] = minPct; changed = true; }
            if (pcts[i] > maxPct){ pcts[i] = maxPct; changed = true; }
          }
          if (!changed) { break; }
        }
        var finalSum = 0;
        for (var i = 0; i < pcts.length; i++){ finalSum += pcts[i]; }
        if (finalSum <= 0) { continue; }
        for (var i = 0; i < pcts.length; i++){ pcts[i] = pcts[i] * 100 / finalSum; }
        var old = table.querySelector('colgroup');
        if (old){ old.parentNode.removeChild(old); }
        var colgroup = document.createElement('colgroup');
        for (var ci = 0; ci < pcts.length; ci++){
          var col = document.createElement('col');
          col.style.width = pcts[ci].toFixed(2) + '%';
          colgroup.appendChild(col);
        }
        table.insertBefore(colgroup, table.firstChild);
        table.style.tableLayout = 'fixed';
        table.dataset.fitted = '1';
      }
    };
    window.__marks = []; window.__searchIdx = -1;
    window.__clearSearch = function(){
      var cs = document.querySelectorAll('mark.srch');
      cs.forEach(function(m){ var p=m.parentNode; while(m.firstChild){ p.insertBefore(m.firstChild, m); } p.removeChild(m); p.normalize(); });
      window.__marks = []; window.__searchIdx = -1;
    };
    function escapeRegExp(s){ return s.replace(/[.*+?^${}()|[\]\\]/g, function(m){ return '\\' + m; }); }
    window.doSearch = function(term){
      window.__clearSearch();
      if(!term){ return 0; }
      var root = document.getElementById('content');
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      var nodes = []; var n;
      while((n = walker.nextNode())){
        var p = n.parentNode;
        // 跳过脚本/样式/已有 mark；且不进入 mermaid SVG 与 KaTeX 公式内部，
        // 否则 mark 包裹会破坏图表/公式渲染（兼容性取舍）
        if(p && p.nodeName !== 'SCRIPT' && p.nodeName !== 'STYLE' && p.nodeName !== 'MARK'
           && !(p.ownerSVGElement) && !(p.closest && p.closest('.katex'))){ nodes.push(n); }
      }
      var re = new RegExp(escapeRegExp(term), 'gi');
      nodes.forEach(function(node){
        var txt = node.nodeValue; var m; var last = 0; re.lastIndex = 0;
        var frag = document.createDocumentFragment();
        while((m = re.exec(txt)) !== null){
          if(m.index > last){ frag.appendChild(document.createTextNode(txt.substring(last, m.index))); }
          var mark = document.createElement('mark'); mark.className = 'srch'; mark.textContent = m[0];
          frag.appendChild(mark);
          last = m.index + m[0].length;
          if(m.index === re.lastIndex){ re.lastIndex++; }
        }
        if(last > 0){ if(last < txt.length){ frag.appendChild(document.createTextNode(txt.substring(last))); } node.parentNode.replaceChild(frag, node); }
      });
      window.__marks = Array.prototype.slice.call(document.querySelectorAll('mark.srch'));
      // 搜索即跳转到第一个关键字处（标准 Cmd+F 行为）
      if(window.__marks.length){
        window.__searchIdx = 0;
        window.__marks[0].classList.add('srch-cur');
        window.__marks[0].scrollIntoView({behavior:'smooth', block:'center'});
      }
      return window.__marks.length;
    };
    window.searchGo = function(dir){
      if(!window.__marks.length){ return -1; }
      if(window.__searchIdx >= 0 && window.__marks[window.__searchIdx]){ window.__marks[window.__searchIdx].classList.remove('srch-cur'); }
      if(dir > 0){ window.__searchIdx = (window.__searchIdx + 1) % window.__marks.length; }
      else { window.__searchIdx = (window.__searchIdx - 1 + window.__marks.length) % window.__marks.length; }
      var cur = window.__marks[window.__searchIdx];
      cur.classList.add('srch-cur');
      cur.scrollIntoView({behavior:'smooth', block:'center'});
      return window.__searchIdx + 1;
    };
    // 双向同步：根据滚动位置计算当前可视章节，回传 heading id 供大纲反向高亮。
    // 1. 标题文档坐标（__docTop）在渲染完成/资源加载后一次性缓存，滚动时零 getBoundingClientRect。
    // 2. 二分查找「最后一个 __docTop <= scrollY+100 的标题」，纯数值比较，无 DOM 访问。
    // 3. active 消息每次章节切换都回传 Swift（大纲高亮 + 阅读进度持久化，不节流以免漏存）。
    window.__recomputeHeads = function(){
      var heads = window.__heads;
      if(!heads || !heads.length){ return; }
      var sy = window.scrollY || 0;
      for (var i = 0; i < heads.length; i++){
        heads[i].__docTop = heads[i].getBoundingClientRect().top + sy;
      }
    };
    window.__lastActive = null;
    window.__onScroll = function(){
      var heads = window.__heads;
      if(!heads || !heads.length){ return; }
      var target = (window.scrollY || 0) + 100;
      var lo = 0, hi = heads.length - 1, idx = -1;
      while(lo <= hi){
        var mid = (lo + hi) >> 1;
        if(heads[mid].__docTop <= target){ idx = mid; lo = mid + 1; }
        else { hi = mid - 1; }
      }
      var active = idx >= 0 ? heads[idx].id : heads[0].id;
      if(active && active !== window.__lastActive){
        window.__lastActive = active;
        // 阅读进度持久化在 Swift 侧（UserDefaults，active 消息每次章节切换都回传）；
        // 不用 localStorage（file:// baseURL 下不持久），也不节流（防快速滚动漏存最终章节）。
        if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.active){
          window.webkit.messageHandlers.active.postMessage(active);
        }
      }
    };
    // 大文档分块懒渲染：滚动接近已渲染区底部时加载下一批。
    // 80ms 时间节流：rAF 每帧调用，getBoundingClientRect 是强制布局查询，不能每帧执行。
    window.__maybeLoadMore = function(){
      var now = Date.now();
      if(now - (window.__lastLoadCheck || 0) < 80){ return; }
      window.__lastLoadCheck = now;
      if(!window.__sections || window.__renderedUpTo >= window.__sections.length - 1){ return; }
      var content = document.getElementById('content');
      var last = content.lastElementChild;
      if(!last){ return; }
      if(last.getBoundingClientRect().bottom < window.innerHeight * 2.5){ window.__renderBatch(4); }
    };
    // 恢复上次阅读位置（按章节 id；分块模式下目标未渲染则先渲染到该段）。
    // 图片/Mermaid 异步加载会改变布局，故 300ms 后重试一次保证滚动到位。
    window.__restoreTo = null;
    window.__doRestore = function(){
      var saved = window.__restoreTo;
      if(!saved){ return; }
      var e = document.getElementById(saved);
      if(!e && window.__sections){
        var n = parseInt(String(saved).replace(/^h-/,''), 10);
        if(!isNaN(n)){
          for (var i = 0; i < window.__sections.length; i++){
            var ss = window.__sections[i].startSeq;
            if(ss < 0){ continue; }   // 引言段无标题，跳过（不能 break）
            if(ss <= n){ window.__renderUpToSection(i); }
            else { break; }
          }
          e = document.getElementById(saved);
        }
      }
      if(e){ e.scrollIntoView({block:'start'}); window.__onScroll && window.__onScroll(); }
    };
    window.__restoreProgress = function(){
      // 上次阅读位置由 Swift 侧从 UserDefaults 读出并注入 window.__savedProgress
      var saved = window.__savedProgress || '';
      if(!saved){ return; }
      window.__restoreTo = saved;
      window.__doRestore();
      setTimeout(function(){ window.__doRestore(); }, 300);
    };
    window.addEventListener('scroll', function(){
      window.requestAnimationFrame(function(){
        window.__onScroll && window.__onScroll();
        window.__maybeLoadMore && window.__maybeLoadMore();
        // 阅读进度回传（顶部进度条）：scrollY / (scrollHeight - innerHeight)，阈值过滤防抖动
        var docEl = document.documentElement;
        var max = (docEl.scrollHeight - window.innerHeight) || 1;
        var p = Math.min(1, Math.max(0, window.scrollY / max));
        if (Math.abs(p - (window.__lastProgress || 0)) > 0.002) {
          window.__lastProgress = p;
        }
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.progress) {
          window.webkit.messageHandlers.progress.postMessage({progress: p, offset: window.scrollY});
        }
      });
    }, {passive:true});
    // 图片等资源异步加载会改变布局，load 后重算标题坐标缓存
    window.addEventListener('load', window.__recomputeHeads);
    // —— 外观主题：由 __forceTheme（'system'|'light'|'dark'）决定，默认跟随系统 ——
    window.applyTheme = function(){
      var mode = window.__forceTheme || 'system';
      var dark = (mode === 'dark') || (mode === 'system' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
      window.__isDark = dark;
      document.documentElement.classList.toggle('theme-dark', dark);
      document.body.classList.toggle('theme-dark', dark);
      document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
      document.documentElement.style.background = dark ? '#0d1117' : '#ffffff';
      // Mermaid SVG 颜色在渲染时写死，切主题必须按新主题重绘，
      // 否则图表停留在旧主题、与页面其它部分割裂。
      // 源文本在首次渲染时存入 pre[data-mermaid-src]，这里直接重渲染替换。
      if(window.mermaid && window.__mermaidInit){
        try {
          window.mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme: dark ? 'dark' : 'default'});
          var boxes = document.querySelectorAll('#content pre.mermaid-box[data-mermaid-src]');
          for (var i = 0; i < boxes.length; i++){
            (function(pre){
              var src = pre.getAttribute('data-mermaid-src');
              window.__mermaidBusy = (window.__mermaidBusy || 0) + 1;
              window.mermaid.render('mmd-' + (window.__mmdId = (window.__mmdId||0) + 1), src)
                .then(function(res){
                  window.__mermaidBusy--;
                  pre.innerHTML = res.svg;
                  if(window.__recomputeHeads){ window.__recomputeHeads(); }
                })
                .catch(function(){ window.__mermaidBusy--; });
            })(boxes[i]);
          }
        } catch(e){}
      }
    };
    // 跟随系统模式下，系统切换外观时自动响应；手动模式不响应
    if(window.matchMedia){
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(){
        if(!window.__forceTheme || window.__forceTheme === 'system'){ window.applyTheme(); }
      });
    }
    """#

    /// 页面加载时执行的渲染 + 大纲回传 IIFE。mdJSON 已是合法 JS 字符串字面量，直接内联。
    /// chunkMode: "auto"（阅读模式，>25 万字符自动分块懒渲染）/ "full"（导出等全量场景）。
    private static func jsRenderInline(mdJSON: String, chunkMode: String) -> String {
        #"""
        (function(){
          try {
            // 页面加载即应用外观主题（跟随系统/强制亮/强制暗）
            window.applyTheme && window.applyTheme();
            window.__mdit = window.markdownit({html:true, linkify:true, typographer:true, breaks:true});
            if(window.markdownitFootnote){ try { window.__mdit.use(window.markdownitFootnote); } catch(e){} }
            if(window.mdPlugins){
              try {
                var P = window.mdPlugins;
                if(P.emoji){ window.__mdit.use(P.emoji); }
                if(P.mark){ window.__mdit.use(P.mark); }
                // 不启用 md-plugins 的 sub（单波浪线 ~x~ 一律当下标）：单波浪线需要按内容
                // 区分下标（H~2~O 数字）与删除线（~文字~，Typora 习惯），见下方自定义 tilde 规则。
                if(P.sup){ window.__mdit.use(P.sup); }
                if(P.deflist){ window.__mdit.use(P.deflist); }
              } catch(e){}
            }
            // —— 数学公式（$...$ / $$...$$）：在 markdown-it 其他行内规则前拦截，避免
            // breaks 的 <br> 切段、反斜杠转义（\,→,）、强调（*_）等破坏公式源码；
            // 直接用 KaTeX 渲染成 HTML。规则放在 strikethrough 之前（backticks 之后），
            // 行内代码里的 $ 已被 backticks 规则消费，不会误伤。
            window.__mdit.inline.ruler.before('strikethrough', 'math', function(state, silent){
              var start = state.pos;
              if (state.src.charCodeAt(start) !== 0x24) { return false; }       // '$'
              var isDisp = state.src.charCodeAt(start + 1) === 0x24;
              var openLen = isDisp ? 2 : 1;
              var closeStr = isDisp ? '$$' : '$';
              var end = state.src.indexOf(closeStr, start + openLen);
              if (end < 0) { return false; }
              var raw = state.src.slice(start + openLen, end);
              if (isDisp) {
                if (!raw.replace(/\s/g, '')) { return false; }                  // 空公式不处理
              } else {
                if (raw.indexOf('\n') >= 0) { return false; }
                if (!raw.trim() || raw !== raw.trim()) { return false; }        // 首尾空白不算公式（$5 and $10 之类）
              }
              if (silent) { return true; }
              var html;
              try { html = window.katex.renderToString(raw.trim(), {displayMode: isDisp, throwOnError: false}); }
              catch(e) { return false; }
              var token = state.push('html_inline', '', 0);
              token.content = html;
              state.pos = end + closeStr.length;
              return true;
            });
            // —— 单波浪线：数字→下标（H~2~O），非数字→删除线（~文字~，Typora 习惯）。
            // 双波浪线 ~~...~~ 由 markdown-it 内置 strikethrough 处理（本规则空内容不匹配）。
            window.__mdit.inline.ruler.before('emphasis', 'tilde', function(state, silent){
              var start = state.pos;
              if (state.src.charCodeAt(start) !== 0x7E) { return false; }       // '~'
              var end = state.src.indexOf('~', start + 1);
              if (end < 0) { return false; }
              var content = state.src.slice(start + 1, end);
              if (!content || content.indexOf('\n') >= 0) { return false; }
              if (content !== content.trim()) { return false; }
              if (silent) { return true; }
              var tag = /^[0-9]+(?:[.,][0-9]+)?$/.test(content) ? 'sub' : 's';
              var o = state.push(tag + '_open', tag, 1); o.markup = '~';
              var t = state.push('text', '', 0); t.content = content;
              var c = state.push(tag + '_close', tag, -1); c.markup = '~';
              state.pos = end + 1;
              return true;
            });
            // —— **粗体** + CJK 全角标点边界：CommonMark 把「」等当作标点，
            // 导致 **「...」** 无法开/闭强调；这里只对边界为 CJK 标点的情况
            // 用 renderInline 重新解析内部内容并包 strong。
            var cjkPunct = /[\u3000-\u303F\uFF01-\uFF5E\u2018\u2019\u201C\u201D\u3008-\u3011]/;
            window.__mdit.inline.ruler.before('emphasis', 'cjk_bold', function(state, silent){
              if (state.src.charCodeAt(state.pos) !== 0x2A || state.src.charCodeAt(state.pos + 1) !== 0x2A) { return false; }
              var end = state.src.indexOf('**', state.pos + 2);
              if (end < 0) { return false; }
              var content = state.src.slice(state.pos + 2, end);
              if (!content || content.indexOf('\n') >= 0 || content.indexOf('**') >= 0) { return false; }
              if (!cjkPunct.test(content.charAt(0)) && !cjkPunct.test(content.charAt(content.length - 1))) { return false; }
              if (silent) { return true; }
              var html = state.md.renderInline(content);
              var token = state.push('html_inline', '', 0);
              token.content = '<strong>' + html + '</strong>';
              state.pos = end + 2;
              return true;
            });
            var src = \#(mdJSON);
            var chunkMode = '\#(chunkMode)';

            // —— 扫描大纲 + 按标题切分（跳过代码围栏），全量/分块两模式共用 ——
            function cleanHeadingText(s){
              // 去除行内 markdown 标记：粗体/斜体/行内码/删除线/链接，避免大纲显示原始语法
              return s.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
                      .replace(/[*_`~]/g, '')
                      .replace(/\s+/g, ' ')
                      .trim();
            }
            function scanAndSplit(text){
              var lines = text.split('\n');
              var outline = []; var sections = []; var cur = []; var inFence = false;
              var seq = 0; var pendingSeq = -1;
              function flush(){ if(cur.length){ sections.push({text: cur.join('\n'), startSeq: pendingSeq}); cur = []; } }
              for (var i = 0; i < lines.length; i++){
                var ln = lines[i];
                if(/^\s*```/.test(ln)){ inFence = !inFence; }
                if(!inFence){
                  var m = /^(#{1,6})\s+(.+)$/.exec(ln);
                  if(m){
                    flush();
                    outline.push({level: m[1].length, text: cleanHeadingText(m[2]), id: 'h-' + seq});
                    pendingSeq = seq; seq++;
                  }
                }
                cur.push(ln);
              }
              flush();
              return {outline: outline, sections: sections};
            }
            function injectAnchor(h){
              var a = document.createElement('a');
              a.className = 'header-anchor'; a.href = '#' + h.id;
              a.setAttribute('aria-hidden', 'true'); a.textContent = '#';
              h.insertBefore(a, h.firstChild);
            }
            // 代码块精致化：语言栏 + 行号栏 + 代码主体。
            // 不拆高亮后的 DOM，而是把 gutter 与 code 并排放进 grid，避免破坏 hljs 结构。
            window.__polishCodeBlocks = function(root){
              var pres = root.querySelectorAll('pre');
              for (var pi = 0; pi < pres.length; pi++){
                var pre = pres[pi];
                if (pre.dataset.polished || pre.classList.contains('mermaid-box')) { continue; }
                let code = pre.querySelector('code');
                if (!code || (code.className || '').indexOf('language-mermaid') >= 0) { continue; }
                pre.classList.add('code-block');
                var langMatch = /(?:^|\s)language-([\w+-]+)/.exec(code.className || '');
                pre.setAttribute('data-lang', langMatch ? langMatch[1] : 'code');
                if (pre.querySelector('.code-gutter')) { continue; }
                var lines = (code.textContent || '').replace(/\n$/, '').split('\n');
                var gutter = document.createElement('div');
                gutter.className = 'code-gutter';
                var nums = [];
                for (var n = 1; n <= lines.length; n++){ nums.push(String(n)); }
                gutter.textContent = nums.join('\n');
                var body = document.createElement('div');
                body.className = 'code-body';
                code.parentNode.replaceChild(body, code);
                body.appendChild(code);
                pre.insertBefore(gutter, body);
                let copy = document.createElement('button');
                copy.type = 'button';
                copy.className = 'code-copy';
                copy.textContent = 'Copy';
                // 事件挂到 pre 上做委托，避免按钮被伪元素/重排吞掉点击。
                pre.addEventListener('click', function(ev){
                  var target = ev.target;
                  if (!target || !target.classList || !target.classList.contains('code-copy')) { return; }
                  var text = code.textContent;
                  copy.textContent = 'Copied';
                  setTimeout(function(){ copy.textContent = 'Copy'; }, 1200);
                  function fallback(){
                    var ta = document.createElement('textarea');
                    ta.value = text;
                    ta.style.position = 'fixed';
                    ta.style.top = '0';
                    ta.style.left = '0';
                    ta.style.opacity = '0';
                    document.body.appendChild(ta);
                    ta.focus();
                    ta.select();
                    try { document.execCommand('copy'); } catch(e){}
                    document.body.removeChild(ta);
                  }
                  if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text).catch(fallback);
                  } else { fallback(); }
                });
                pre.appendChild(copy);
                pre.dataset.polished = '1';
              }
            };
            // 段渲染 + 后处理：标题 id/锚点、图片懒加载、KaTeX、代码高亮（分帧）
            window.__mdit.renderSection = function(section, container, syncHighlight){
              var html = window.__mdit.render(section.text);
              // 任务复选框仅展示（不可编辑）：[ ] 显示未勾选，[x]/[X] 显示勾选，均 disabled。
              html = html.replace(/<li>\s*\[ \]\s+/g, '<li class="task"><input type="checkbox" disabled> ')
                         .replace(/<li>\s*\[[xX]\]\s+/g, '<li class="task"><input type="checkbox" disabled checked> ');
              container.innerHTML = html;
              window.__fitTables(container);
              var hs = container.querySelectorAll('h1,h2,h3,h4,h5,h6');
              for (var k = 0; k < hs.length; k++){
                if(section.startSeq >= 0){ hs[k].id = 'h-' + (section.startSeq + k); }
                injectAnchor(hs[k]);
              }
              container.querySelectorAll('img').forEach(function(im){ im.loading = 'lazy'; im.decoding = 'async'; });
              var codes = Array.prototype.slice.call(container.querySelectorAll('pre code'));
              if(!window.hljs){ window.__polishCodeBlocks(container); return; }
              if(syncHighlight || codes.length <= 12){
                codes.forEach(function(b){ try { window.hljs.highlightElement(b); } catch(e){} });
                window.__polishCodeBlocks(container);
              } else {
                window.__highlightQueue = (window.__highlightQueue || []).concat(codes);
                window.__polishRoots = (window.__polishRoots || []).concat(container);
                if(!window.__highlighting){
                  window.__highlighting = true;
                  (function drain(){
                    var batch = window.__highlightQueue.splice(0, 8);
                    batch.forEach(function(b){ try { window.hljs.highlightElement(b); } catch(e){} });
                    if(window.__highlightQueue.length){ window.requestAnimationFrame(drain); }
                    else {
                      window.__highlighting = false;
                      (window.__polishRoots || []).forEach(function(r){ window.__polishCodeBlocks(r); });
                      window.__polishRoots = [];
                    }
                  })();
                }
              }
            };
            function recomputeAll(){ if(window.__recomputeHeads){ window.__recomputeHeads(); } if(window.__onScroll){ window.__onScroll(); } }
            // Mermaid：按需渲染，语法错误/异常一律保留原代码块（取舍原则）
            window.__renderMermaid = function(){
              var mmdEls = document.querySelectorAll('#content pre code.language-mermaid');
              if(!window.mermaid || !mmdEls.length){ return; }
              try {
                if(!window.__mermaidInit){
                  window.mermaid.initialize({
                    startOnLoad: false, securityLevel: 'strict',
                    // 跟随实际生效主题（手动模式也一致），而非直接读系统 matchMedia
                    theme: window.__isDark ? 'dark' : 'default',
                    fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif'
                  });
                  window.__mermaidInit = true;
                }
                var jobs = [];
                Array.prototype.forEach.call(mmdEls, function(codeEl){
                  // 源文本存入 pre[data-mermaid-src]：外观切换时按新主题重绘需要
                  var pre0 = codeEl.closest('pre');
                  if(pre0){ pre0.setAttribute('data-mermaid-src', codeEl.textContent); }
                  codeEl.classList.remove('hljs');
                  // busy 计数：渲染是异步的，导出（PDF/HTML）需轮询它归零后再抓取
                  window.__mermaidBusy = (window.__mermaidBusy || 0) + 1;
                  jobs.push(window.mermaid.render('mmd-' + (window.__mmdId = (window.__mmdId||0) + 1), codeEl.textContent)
                    .then(function(res){
                      window.__mermaidBusy--;
                      var pre = codeEl.closest('pre');
                      if(pre){ pre.classList.add('mermaid-box'); pre.innerHTML = res.svg; }
                    })
                    .catch(function(){ window.__mermaidBusy--; }));
                });
                Promise.all(jobs).then(function(){ recomputeAll(); });
              } catch(e){}
            };
            // 分块模式下增量收集已渲染标题（未渲染的没有 DOM，不参与坐标缓存）
            function appendHeads(container){
              if(!window.__heads){ window.__heads = []; }
              Array.prototype.push.apply(window.__heads, Array.prototype.slice.call(container.querySelectorAll('h1,h2,h3,h4,h5,h6')));
            }

            var scan = scanAndSplit(src);
            window.__outline = scan.outline;
            window.__chunked = (chunkMode === 'auto') ? (src.length > 250000) : false;

            if(!window.__chunked){
              // —— 全量渲染（小文档 / 导出） ——
              window.__sections = null;
              window.__renderAll = function(){ return true; };
              var content = document.getElementById('content');
              window.__mdit.renderSection({text: src, startSeq: 0}, content, false);
              window.__heads = Array.prototype.slice.call(content.querySelectorAll('h1,h2,h3,h4,h5,h6'));
              if(window.__recomputeHeads){ window.__recomputeHeads(); }
              if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.outline){
                window.webkit.messageHandlers.outline.postMessage(window.__outline);
              }
              window.__onScroll && window.__onScroll();
              window.__renderMermaid();
              window.__restoreProgress && window.__restoreProgress();
            } else {
              // —— 分块懒渲染（大文档）：初始 6 段，滚动渐进加载 ——
              window.__sections = scan.sections;
              window.__renderedUpTo = -1;
              window.__renderBatch = function(count){
                var end = Math.min(window.__renderedUpTo + count, window.__sections.length - 1);
                for (var i = window.__renderedUpTo + 1; i <= end; i++){
                  var div = document.createElement('div');
                  div.className = 'md-section';
                  window.__mdit.renderSection(window.__sections[i], div, false);
                  document.getElementById('content').appendChild(div);
                  appendHeads(div);
                }
                window.__renderedUpTo = end;
                recomputeAll();
                window.__renderMermaid();
                window.__maybeLoadMore && window.__maybeLoadMore();
              };
              window.__renderUpToSection = function(i){
                if(i > window.__renderedUpTo){ window.__renderBatch(i - window.__renderedUpTo); }
              };
              window.__renderAll = function(){
                var end = window.__sections.length - 1;
                for (var i = window.__renderedUpTo + 1; i <= end; i++){
                  var div = document.createElement('div');
                  div.className = 'md-section';
                  window.__mdit.renderSection(window.__sections[i], div, true);
                  document.getElementById('content').appendChild(div);
                  appendHeads(div);
                }
                window.__renderedUpTo = end;
                recomputeAll();
                window.__renderMermaid();
                // 同步返回（不能返回 Promise）
                return true;
              };
              window.__renderBatch(6);
              if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.outline){
                window.webkit.messageHandlers.outline.postMessage(window.__outline);
              }
              window.__restoreProgress && window.__restoreProgress();
            }
          } catch(err) {
            if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.outline){
              window.webkit.messageHandlers.outline.postMessage([]);
            }
          }
        })();
        """#
    }
}

/// WKWebView 导航与消息回调。
/// - didFinish：通知 renderer 兜底读取大纲。
/// - 大纲消息：页面脚本 postMessage 后在此接收并切回主线程写入 renderer.outline。
@MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var renderer: MarkdownRenderer?

    // WKScriptMessageHandler 协议在 SDK 中是 @MainActor（WK_SWIFT_UI_ACTOR），
    // 此回调由 WebKit 在主线程调用。
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "outline" {
            let heads: [Heading]
            if let arr = message.body as? [[String: Any]] {
                heads = parseOutline(arr)
            } else {
                heads = []
            }
            // 判等写入：双通道（postMessage + didFinish 兜底）可能重复赋值，
            // @Published 不判等，相同值 set 也会触发 objectWillChange 引发整树重算。
            guard let r = renderer, r.outline != heads else { return }
            r.outline = heads
        } else if message.name == "active" {
            guard let id = message.body as? String, let r = renderer, r.activeHeadingID != id else { return }
            r.activeHeadingID = id
            // 阅读进度持久化：每次章节切换写入 UserDefaults（恢复时 render() 读回注入页面）
            r.saveProgress(id)
        } else if message.name == "progress" {
            guard let r = renderer else { return }
            let progress: Double
            let offset: Double
            if let body = message.body as? [String: Any] {
                guard let p = (body["progress"] as? NSNumber)?.doubleValue else { return }
                progress = p
                offset = (body["offset"] as? NSNumber)?.doubleValue ?? r.renderedScrollOffset
            } else if let p = (message.body as? NSNumber)?.doubleValue {
                progress = p
                offset = r.renderedScrollOffset
            } else {
                return
            }
            r.updateRenderedScrollOffset(offset)
            guard r.readingProgress != progress else { return }
            r.readingProgress = progress
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        renderer?.didFinishNavigation()
    }

}

/// 导出相关错误。
enum ExportError: LocalizedError {
    /// 页面仍在渲染（pageLoaded 闸门未通过），导出会拿到空白/半成品。
    case pageNotLoaded
    /// createPDF 未返回数据也未报错（异常分支）。
    case pdfGenerationFailed

    var errorDescription: String? {
        switch self {
        case .pageNotLoaded:
            return "The document is still rendering. Try again in a moment."
        case .pdfGenerationFailed:
            return "Failed to generate PDF."
        }
    }
}
