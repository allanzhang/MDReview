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

        let width: CGFloat = 520
        let height: CGFloat = 54
        let bar = SearchBar(renderer: renderer, text: text, onClose: onClose)
        let host = NSHostingView(rootView: bar)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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

    /// 面板定位：水平居中于窗口、垂直贴窗口顶部（标题栏区域，略下移 6pt 悬空覆盖文件名/路径）。
    private func position(_ panel: NSPanel, relativeTo window: NSWindow) {
        let winFrame = window.frame
        let size = panel.frame.size
        let x = winFrame.midX - size.width / 2
        let y = winFrame.maxY - size.height - 6
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
