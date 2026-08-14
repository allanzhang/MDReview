import AppKit
import SwiftUI

/// 浮动搜索面板：点击搜索按钮时，在窗口标题栏中央（文件名/路径位置）悬空浮出一个
/// 无边框玻璃搜索框（Spotlight 式）。原窗口布局完全不变，面板是独立浮层。
@MainActor final class SearchPanelController {
    static let shared = SearchPanelController()

    private var panel: NSPanel?
    private weak var observedWindow: NSWindow?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 显示/切换面板。传入渲染器与搜索文本 binding（由调用方 ContentView 持有）。
    func toggle(renderer: MarkdownRenderer, text: Binding<String>, onClose: @escaping () -> Void) {
        if isVisible {
            hide()
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let height: CGFloat = 58
        let bar = SearchBar(renderer: renderer, text: text, onClose: onClose)
        let host = NSHostingView(rootView: bar)
        // 透明背景：面板透明，让 SwiftUI material 毛玻璃生效
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // 阴影由 SwiftUI SearchBar 自身绘制
        panel.hidesOnDeactivate = false
        panel.contentView = host

        position(panel, relativeTo: window)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // 跟随主窗口移动/缩放
        observe(window)
        // 面板内 SearchBar 的 onAppear 聚焦输入框
        DispatchQueue.main.async { host.rootView = bar }
    }

    func hide() {
        panel?.orderOut(nil)
        if let w = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: w)
        }
        observedWindow = nil
    }

    /// 面板定位：水平居中对齐「Open」与「Search」按钮中点（按按钮 toolTip 匹配），
    /// 宽度随窗口 55% 自适应（320-720）；匹配失败回退窗口顶部居中。
    private func position(_ panel: NSPanel, relativeTo window: NSWindow) {
        let width = max(320, min(window.frame.width * 0.55, 720))
        let height = panel.frame.height
        panel.setContentSize(NSSize(width: width, height: height))

        var anchor: NSPoint?
        if let toolbar = window.toolbar {
            var openFrame: NSRect?
            var searchFrame: NSRect?
            for item in toolbar.items {
                guard let view = item.view else { continue }
                let tip = view.toolTip ?? ""
                let r = view.convert(view.bounds, to: nil)   // 屏幕坐标（AppKit 左下原点）
                if tip.contains("Open Markdown") {
                    openFrame = r
                } else if tip.contains("Search in Document") {
                    searchFrame = r
                }
            }
            if let o = openFrame, let s = searchFrame {
                anchor = NSPoint(x: (o.midX + s.midX) / 2, y: (o.midY + s.midY) / 2)
            }
        }

        let x: CGFloat
        let y: CGFloat
        if let anchor {
            x = anchor.x - width / 2
            y = anchor.y - height / 2
        } else {
            let wf = window.frame
            x = wf.midX - width / 2
            y = wf.maxY - height - 10
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func observe(_ window: NSWindow) {
        if let w = observedWindow, w !== window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: w)
        }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didMoveNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFrameChanged(_:)),
            name: NSWindow.didResizeNotification, object: window
        )
    }

    @objc private func windowFrameChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, let panel, isVisible else { return }
        position(panel, relativeTo: window)
    }
}
