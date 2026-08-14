import Foundation
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

/// 渲染控制器：持有唯一的 WKWebView，负责加载本地 markdown-it + KaTeX，
/// 把 MD 字符串渲染为 HTML，并通过消息通道取回大纲，提供滚动定位、全文搜索。
///
/// 设计要点（相较旧版的稳定性改进）：
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

    /// 标记当前页面导航已完成，未就绪时禁止 evaluateJavaScript（修复“持续报错”）。
    private var pageLoaded = false

    override init() {
        // Coordinator 仅在 init 内创建并交给 WKWebView 持有，避免与 renderer 形成强引用环。
        let coord = Coordinator()

        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 注册大纲回传通道：页面脚本 window.webkit.messageHandlers.outline.postMessage(...)
        config.userContentController.add(coord, name: "outline")
        // 注册可视章节回传通道：页面滚动时回传当前 heading id，用于大纲反向高亮
        config.userContentController.add(coord, name: "active")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.autoresizingMask = [.width, .height]
        webView = wv
        super.init()
        coord.renderer = self
        webView.navigationDelegate = coord
    }

    /// 用内联了 markdown 的 HTML 重新加载页面。baseURL 设为 .md 所在目录，使相对图片路径可解析。
    /// docName 为文件名，用于阅读进度记忆（localStorage key 区分不同文档）。
    func render(_ markdown: String, baseURL: URL?, docName: String? = nil, appearance: AppearanceMode = .system) {
        pageLoaded = false
        webView.loadHTMLString(Self.htmlTemplate(markdown: markdown, docName: docName, chunkMode: "auto", appearance: appearance), baseURL: baseURL)
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

    /// 导出当前渲染结果为 PDF（多页，含代码高亮 / KaTeX / 样式，与屏幕渲染一致）。
    /// 基于 WKWebView 原生 createPDF（macOS 11+，completionHandler 版本经 continuation 包装），无额外依赖。
    func exportPDF(to url: URL) async throws {
        guard pageLoaded else { throw ExportError.pageNotLoaded }
        // 分块懒渲染模式下先强制渲染全文，确保 PDF 完整（evaluateJavaScript 会等待 Promise resolve）
        try await evaluateJS("(window.__renderAll ? window.__renderAll() : true)")
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

    func search(_ term: String) {
        guard pageLoaded else { return }
        let script = "doSearch(\(Self.jsonString(for: term)))"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let count = (result as? Int) ?? 0
            DispatchQueue.main.async { self.searchCount = count; self.searchCurrent = 0 }
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

    // MARK: - 模板与脚本

    /// 把 Swift 字符串安全转成 JS 字符串字面量（正确转义引号/反斜杠/换行）。
    /// JSON 顶层只接受 array/dictionary，故先包成数组序列化，再去掉首尾方括号。
    private static func jsonString(for s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let raw = String(data: data, encoding: .utf8) ?? "[]"
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
        // hljsDark 已 scoped（body.theme-dark 前缀），不再包 @media，改由 JS 按 class 控制
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
    static func htmlTemplate(markdown: String, docName: String? = nil, chunkMode: String = "auto", appearance: AppearanceMode = .system) -> String {
        let mdJSON = jsonString(for: markdown)
        let renderScript = "<script>\(jsRenderInline(mdJSON: mdJSON, chunkMode: chunkMode))</script>"
        // 注入文件名供阅读进度记忆使用（localStorage key 区分不同文档）
        let docNameScript = "<script>window.__docName = \(jsonString(for: docName ?? ""));</script>"
        // 注入外观模式供 applyTheme 使用
        let themeScript = "<script>window.__forceTheme = '\(appearance.rawValue)';</script>"
        let mermaidScript = markdown.contains("```mermaid") ? "<script>\(bundled.mermaid)</script>" : ""

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(headHTML)\(scriptsHTML)\(docNameScript)\(themeScript)\(mermaidScript)</head>
        <body><article id="content"></article>\(renderScript)</body></html>
        """
    }

    /// 滚动 / 搜索 / 正则转义等工具函数（不含渲染，渲染见 jsRenderInline）。
    /// 使用原始字符串保留正则中的反斜杠。
    private static let jsFunctions = #"""
    // 大纲点击跳转：用瞬时滚动（不用 smooth）。smooth 动画期间持续触发 scroll 事件，
    // 每帧都跑 __onScroll 的布局查询 + SwiftUI 反向高亮更新，长文档下是卡顿主因之一。
    window.scrollToHeading = function(id){ var e=document.getElementById(id); if(e){ e.scrollIntoView({block:'start'}); } };
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
    // 性能要点（第二次优化，v2）：
    // 1. 标题文档坐标（__docTop）在渲染完成/资源加载后一次性缓存，滚动时零 getBoundingClientRect
    //    （旧版每帧 O(N) layout 查询，v1 改二分后仍每帧 O(log N) 次强制布局）。
    // 2. 二分查找「最后一个 __docTop <= scrollY+100 的标题」，纯数值比较，无 DOM 访问。
    // 3. active 消息 40ms 节流：惯性滚动高频变化时最多约 25 次/秒回传 Swift，避免打满主线程。
    window.__recomputeHeads = function(){
      var heads = window.__heads;
      if(!heads || !heads.length){ return; }
      var sy = window.scrollY || 0;
      for (var i = 0; i < heads.length; i++){
        heads[i].__docTop = heads[i].getBoundingClientRect().top + sy;
      }
    };
    window.__lastActive = null;
    window.__lastActiveSent = 0;
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
        // 阅读进度保存与发送节流【解耦】：每次章节切换立即写 localStorage。
        // （原实现与 40ms 节流共用一块，快速滚动时最终章节可能落在节流窗口内而漏存，
        //   切走再切回就恢复到旧章节——即用户反馈的“无法记住滚动位置”。）
        if(window.__docName){
          try { window.localStorage.setItem('mdreview.prog.' + window.__docName, active); } catch(e){}
        }
        var now = Date.now();
        if(now - window.__lastActiveSent >= 40){
          window.__lastActiveSent = now;
          if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.active){
            window.webkit.messageHandlers.active.postMessage(active);
          }
        }
      }
    };
    // 大文档分块懒渲染：滚动接近已渲染区底部时加载下一批
    window.__maybeLoadMore = function(){
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
            if(window.__sections[i].startSeq >= 0 && window.__sections[i].startSeq <= n){
              window.__renderUpToSection(i);
            } else { break; }
          }
          e = document.getElementById(saved);
        }
      }
      if(e){ e.scrollIntoView({block:'start'}); window.__onScroll && window.__onScroll(); }
    };
    window.__restoreProgress = function(){
      if(!window.__docName){ return; }
      var saved = null;
      try { saved = window.localStorage.getItem('mdreview.prog.' + window.__docName); } catch(e){}
      if(!saved){ return; }
      window.__restoreTo = saved;
      window.__doRestore();
      setTimeout(function(){ window.__doRestore(); }, 300);
    };
    window.addEventListener('scroll', function(){
      window.requestAnimationFrame(function(){
        window.__onScroll && window.__onScroll();
        window.__maybeLoadMore && window.__maybeLoadMore();
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
                if(P.sub){ window.__mdit.use(P.sub); }
                if(P.sup){ window.__mdit.use(P.sup); }
                if(P.deflist){ window.__mdit.use(P.deflist); }
              } catch(e){}
            }
            var src = \#(mdJSON);
            var chunkMode = '\#(chunkMode)';

            // —— 扫描大纲 + 按标题切分（跳过代码围栏），全量/分块两模式共用 ——
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
                    outline.push({level: m[1].length, text: m[2], id: 'h-' + seq});
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
            // 段渲染 + 后处理：标题 id/锚点、图片懒加载、KaTeX、代码高亮（分帧）
            window.__mdit.renderSection = function(section, container, syncHighlight){
              var html = window.__mdit.render(section.text);
              html = html.replace(/<li>\s*\[ \]\s+/g, '<li class="task"><input type="checkbox" disabled> ')
                         .replace(/<li>\s*\[x\]\s+/g, '<li class="task"><input type="checkbox" disabled checked> ');
              container.innerHTML = html;
              var hs = container.querySelectorAll('h1,h2,h3,h4,h5,h6');
              for (var k = 0; k < hs.length; k++){
                if(section.startSeq >= 0){ hs[k].id = 'h-' + (section.startSeq + k); }
                injectAnchor(hs[k]);
              }
              container.querySelectorAll('img').forEach(function(im){ im.loading = 'lazy'; im.decoding = 'async'; });
              if(window.renderMathInElement){ try { renderMathInElement(container, {delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}], throwOnError:false}); } catch(e){} }
              var codes = Array.prototype.slice.call(container.querySelectorAll('pre code'));
              if(!window.hljs){ return; }
              if(syncHighlight || codes.length <= 12){
                codes.forEach(function(b){ try { window.hljs.highlightElement(b); } catch(e){} });
              } else {
                window.__highlightQueue = (window.__highlightQueue || []).concat(codes);
                if(!window.__highlighting){
                  window.__highlighting = true;
                  (function drain(){
                    var batch = window.__highlightQueue.splice(0, 8);
                    batch.forEach(function(b){ try { window.hljs.highlightElement(b); } catch(e){} });
                    if(window.__highlightQueue.length){ window.requestAnimationFrame(drain); }
                    else { window.__highlighting = false; }
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
                  codeEl.classList.remove('hljs');
                  jobs.push(window.mermaid.render('mmd-' + (window.__mmdId = (window.__mmdId||0) + 1), codeEl.textContent)
                    .then(function(res){ var pre = codeEl.closest('pre'); if(pre){ pre.classList.add('mermaid-box'); pre.innerHTML = res.svg; } })
                    .catch(function(){}));
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
              window.__renderAll = function(){ return Promise.resolve(true); };
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
                return Promise.resolve(true);
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

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "outline" {
            let heads: [Heading]
            if let arr = message.body as? [[String: Any]] {
                heads = parseOutline(arr)
            } else {
                heads = []
            }
            Task { @MainActor [weak self] in
                // 判等写入：双通道（postMessage + didFinish 兜底）可能重复赋值，
                // @Published 不判等，相同值 set 也会触发 objectWillChange 引发整树重算。
                guard let r = self?.renderer, r.outline != heads else { return }
                r.outline = heads
            }
        } else if message.name == "active" {
            guard let id = message.body as? String else { return }
            Task { @MainActor [weak self] in
                guard let r = self?.renderer, r.activeHeadingID != id else { return }
                r.activeHeadingID = id
            }
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
