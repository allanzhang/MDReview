import AppKit
import SwiftUI

/// 无边框面板必须能成为 key window，否则内部输入框无法聚焦（borderless 默认 canBecomeKey=false）。
@MainActor private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 浮动搜索面板：点击搜索按钮时，在 Open 与 Search 按钮之间居中悬空浮出一个
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

        let height: CGFloat = 52
        let bar = SearchBar(renderer: renderer, text: text, onClose: onClose)
        let host = NSHostingView(rootView: bar)
        // 透明 + 圆角裁剪（在宿主层裁圆角，保证圆角外透出背后内容）
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = KeyablePanel(
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
    }

    func hide() {
        panel?.orderOut(nil)
        if let w = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: w)
        }
        observedWindow = nil
    }

    /// 面板定位与尺寸：
    /// - 高度 = 工具栏区域总高（窗口 frame 高 − 内容布局高 = 标题栏+工具栏，
    ///   macOS 26 Liquid Glass 下即按钮所在玻璃背景条的实际高度）
    /// - 宽度 = Open/Search 按钮水平距离的 70%
    /// - 水平 + 垂直双居中于两按钮中点（贴工具栏）
    /// 按钮识别：toolTip（.help 设置）与 label 都查——SwiftUI toolbar item 的 label 常为空。
    /// 锚点不可用/异常时回退窗口顶部居中。
    private func position(_ panel: NSPanel, relativeTo window: NSWindow) {
        var openFrame: NSRect?
        var searchFrame: NSRect?

        if let toolbar = window.toolbar {
            for item in toolbar.items {
                guard let view = item.view, let vw = view.window else { continue }
                let id = (item.label + " " + (view.toolTip ?? "")).lowercased()
                // ⚠️ view.convert(bounds, to: nil) 得到的是【窗口坐标】（原点=窗口左下角），
                // 必须再经 convertToScreen 转成【屏幕坐标】才能与 setFrameOrigin 匹配。
                let r = vw.convertToScreen(view.convert(view.bounds, to: nil))
                if id.contains("open") {
                    openFrame = r
                } else if id.contains("search") {
                    searchFrame = r
                }
            }
        }

        let width: CGFloat
        let height: CGFloat
        let x: CGFloat
        let y: CGFloat

        if let o = openFrame, let s = searchFrame {
            // 高度 = 工具栏区域总高（按钮背景矩形实际高度）
            let chromeH = max(28, window.frame.height - window.contentLayoutRect.height)
            height = chromeH
            // 宽度 = 两按钮水平间距的 50%（下限 220 保证可输入）
            width = max(220, (s.midX - o.midX) * 0.5)
            // 水平：居中于两按钮中点
            x = (o.midX + s.midX) / 2 - width / 2
            // 垂直：以工具栏条为基准居中（用按钮中点会因按钮偏上而顶出窗口上沿）
            y = window.frame.maxY - chromeH / 2 - height / 2
        } else {
            // 回退：窗口顶部居中（屏幕坐标，永不飞出）
            let wf = window.frame
            height = 30
            width = max(220, min(wf.width * 0.4, 520))
            x = wf.midX - width / 2
            y = wf.maxY - height - 8
        }

        panel.setContentSize(NSSize(width: width, height: height))
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
