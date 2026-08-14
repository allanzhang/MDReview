import SwiftUI
import WebKit

/// 把 renderer 持有的 WKWebView 直接作为 NSView 呈现。
struct ReaderWebView: NSViewRepresentable {
    let renderer: MarkdownRenderer

    func makeNSView(context: Context) -> WKWebView {
        renderer.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
