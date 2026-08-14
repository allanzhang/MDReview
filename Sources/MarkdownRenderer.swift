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
                DispatchQueue.main.async { self.outline = heads }
            }
        }
    }

    func scrollTo(_ id: String) {
        guard pageLoaded else { return }
        webView.evaluateJavaScript("scrollToHeading('\(id)')", completionHandler: nil)
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

    /// 把 markdown-it / katex 的 JS、CSS 全部内联进 HTML，避免 file:// 跨源加载问题。
    /// 图片相对路径由 WebView 的 baseURL（.md 目录）解析。
    /// markdown 内容直接内联，页面加载即完成渲染并回传大纲，单次导航更稳健。
    private static func htmlTemplate(markdown: String) -> String {
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
        let md = (try? String(contentsOf: bundle.url(forResource: "markdown-it.min", withExtension: "js")!)) ?? ""
        let kx = (try? String(contentsOf: bundle.url(forResource: "katex.min", withExtension: "js")!)) ?? ""
        let ar = (try? String(contentsOf: bundle.url(forResource: "katex-auto-render.min", withExtension: "js")!)) ?? ""
        let footnote = (try? String(contentsOf: bundle.url(forResource: "markdown-it-footnote.min", withExtension: "js")!)) ?? ""
        let hljs = (try? String(contentsOf: bundle.url(forResource: "highlight.min", withExtension: "js")!)) ?? ""
        let hljsLight = (try? String(contentsOf: bundle.url(forResource: "github.min", withExtension: "css")!)) ?? ""
        // 暗色 hljs 主题包在媒体查询内，跟随系统明暗自动切换；亮色主题为默认。
        let hljsDark = (try? String(contentsOf: bundle.url(forResource: "github-dark.min", withExtension: "css")!)) ?? ""

        let head = "<style>\(readerCSS)\n\(kcss)\n\(hljsLight)\n@media (prefers-color-scheme: dark){ \(hljsDark) }</style>"
        // 渲染库 + 脚注插件 + 高亮库 + 滚动/搜索/工具函数定义
        let scripts = "<script>\(md)</script><script>\(kx)</script><script>\(ar)</script><script>\(footnote)</script><script>\(hljs)</script><script>\(jsFunctions)</script>"
        let mdJSON = jsonString(for: markdown)
        // 页面加载时立即渲染并回传大纲
        let renderScript = "<script>\(jsRenderInline(mdJSON: mdJSON))</script>"

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(head)\(scripts)</head>
        <body><article id="content"></article>\(renderScript)</body></html>
        """
    }

    /// 滚动 / 搜索 / 正则转义等工具函数（不含渲染，渲染见 jsRenderInline）。
    /// 使用原始字符串保留正则中的反斜杠。
    private static let jsFunctions = #"""
    window.scrollToHeading = function(id){ var e=document.getElementById(id); if(e){ e.scrollIntoView({behavior:'smooth', block:'start'}); } };
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
    window.__lastActive = null;
    window.__onScroll = function(){
      var heads = document.querySelectorAll('#content h1,#content h2,#content h3,#content h4,#content h5,#content h6');
      var active = null;
      for (var i = 0; i < heads.length; i++){
        if(heads[i].getBoundingClientRect().top <= 100){ active = heads[i].id; } else { break; }
      }
      if(!active && heads.length){ active = heads[0].id; }
      if(active && active !== window.__lastActive){
        window.__lastActive = active;
        if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.active){
          window.webkit.messageHandlers.active.postMessage(active);
        }
      }
    };
    window.addEventListener('scroll', function(){ window.requestAnimationFrame(window.__onScroll); }, {passive:true});
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
                self?.renderer?.outline = heads
            }
        } else if message.name == "active" {
            guard let id = message.body as? String else { return }
            Task { @MainActor [weak self] in
                self?.renderer?.activeHeadingID = id
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        renderer?.didFinishNavigation()
    }
}
