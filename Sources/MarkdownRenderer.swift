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
    func render(_ markdown: String, baseURL: URL?) {
        pageLoaded = false
        webView.loadHTMLString(Self.htmlTemplate(markdown: markdown), baseURL: baseURL)
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
    private static let bundled: (readerCSS: String, katexCSS: String, md: String, kx: String, ar: String, footnote: String, hljs: String, hljsLight: String, hljsDark: String) = {
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
                (try? String(contentsOf: bundle.url(forResource: "github-dark.min", withExtension: "css")!)) ?? "")
    }()
    private static let headHTML: String = {
        let b = bundled
        return "<style>\(b.readerCSS)\n\(b.katexCSS)\n\(b.hljsLight)\n@media (prefers-color-scheme: dark){ \(b.hljsDark) }</style>"
    }()
    private static let scriptsHTML: String = {
        let b = bundled
        return "<script>\(b.md)</script><script>\(b.kx)</script><script>\(b.ar)</script><script>\(b.footnote)</script><script>\(b.hljs)</script><script>\(jsFunctions)</script>"
    }()

    /// 把 markdown-it / katex 的 JS、CSS 全部内联进 HTML，避免 file:// 跨源加载问题。
    /// 图片相对路径由 WebView 的 baseURL（.md 目录）解析。
    /// markdown 内容直接内联，页面加载即完成渲染并回传大纲，单次导航更稳健。
    private static func htmlTemplate(markdown: String) -> String {
        let mdJSON = jsonString(for: markdown)
        // 页面加载时立即渲染并回传大纲
        let renderScript = "<script>\(jsRenderInline(mdJSON: mdJSON))</script>"

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(headHTML)\(scriptsHTML)</head>
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
      while((n = walker.nextNode())){ var p = n.parentNode; if(p && p.nodeName !== 'SCRIPT' && p.nodeName !== 'STYLE' && p.nodeName !== 'MARK'){ nodes.push(n); } }
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
        var now = Date.now();
        if(now - window.__lastActiveSent >= 40){
          window.__lastActiveSent = now;
          if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.active){
            window.webkit.messageHandlers.active.postMessage(active);
          }
        }
      }
    };
    window.addEventListener('scroll', function(){ window.requestAnimationFrame(window.__onScroll); }, {passive:true});
    // 图片等资源异步加载会改变布局，load 后重算标题坐标缓存
    window.addEventListener('load', window.__recomputeHeads);
    """#

    /// 页面加载时执行的渲染 + 大纲回传 IIFE。mdJSON 已是合法 JS 字符串字面量，直接内联。
    private static func jsRenderInline(mdJSON: String) -> String {
        #"""
        (function(){
          try {
            window.__mdit = window.markdownit({html:true, linkify:true, typographer:true, breaks:true});
            if(window.markdownitFootnote){ try { window.__mdit.use(window.markdownitFootnote); } catch(e){} }
            var src = \#(mdJSON);
            var html = window.__mdit.render(src);
            html = html.replace(/<li>\s*\[ \]\s+/g, '<li class="task"><input type="checkbox" disabled> ')
                       .replace(/<li>\s*\[x\]\s+/g, '<li class="task"><input type="checkbox" disabled checked> ');
            var el = document.getElementById('content');
            el.innerHTML = html;
            if(window.hljs){ try { document.querySelectorAll('#content pre code').forEach(function(b){ window.hljs.highlightElement(b); }); } catch(e){} }
            var heads = el.querySelectorAll('h1,h2,h3,h4,h5,h6');
            var outline = [];
            heads.forEach(function(h, i){ if(!h.id){ h.id = 'h-' + i; } outline.push({level: parseInt(h.tagName.substring(1)), text: h.textContent, id: h.id}); });
            if(window.renderMathInElement){ try { renderMathInElement(el, {delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}], throwOnError:false}); } catch(e){} }
            // KaTeX 渲染（改变布局）完成后才缓存标题列表与文档坐标，供 __onScroll 零布局查询使用
            window.__heads = Array.prototype.slice.call(heads);
            if(window.__recomputeHeads){ window.__recomputeHeads(); }
            window.__outline = outline;
            if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.outline){
              window.webkit.messageHandlers.outline.postMessage(outline);
            }
            if(window.__onScroll){ window.__onScroll(); }
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
