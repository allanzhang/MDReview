import AppKit
import SwiftUI

/// 无边框面板必须能成为 key window，否则内部输入框无法聚焦（borderless 默认 canBecomeKey=false）。
@MainActor private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 浮动搜索面板：点击搜索按钮时，在 Open 与 Search 按钮之间悬空浮出一个
/// 无边框玻璃搜索框（Spotlight 式）。原窗口布局完全不变，面板是独立浮层。
///
/// 实现要点（历史教训）：
/// - 独立 NSPanel（非 childWindow——macOS 26 上 childWindow+borderless 面板偶发不显示）。
/// - 定位统一用【屏幕坐标】：按钮 convert(bounds, to: nil) 是窗口坐标，必须经
///   convertToScreen 转换后 setFrameOrigin（单位混用是"飞到窗外"的根源）。
/// - 拖动/缩放同步：didMove/didResize 监听重定位，但【尺寸缓存】——移动时不再反复
///   setContentSize 触发布局，只 setFrameOrigin，消除此前的"卡卡"感。
/// - 垂直：面板在工具栏条内居中且上下留白（悬空感），不贴窗口顶。
@MainActor final class SearchPanelController {
    static let shared = SearchPanelController()

    private var panel: NSPanel?
    private weak var observedWindow: NSWindow?
    /// 尺寸缓存：拖动时尺寸不变则跳过 setContentSize（避免反复布局卡顿）。
    private var lastSize: NSSize = .zero

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 显示/切换面板。传入渲染器与搜索文本 binding（由调用方 ContentView 持有）。
    func toggle(renderer: MarkdownRenderer, text: Binding<String>, onClose: @escaping () -> Void) {
        if isVisible {
            hide()
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let bar = SearchBar(renderer: renderer, text: text, onClose: onClose)
        let host = NSHostingView(rootView: bar)
        // 透明 + 圆角裁剪（在宿主层裁圆角，保证圆角外透出背后内容）
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        host.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
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

        lastSize = .zero
        position(panel, relativeTo: window)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        observe(window)
    }

    func hide() {
        panel?.orderOut(nil)
        if let w = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: w)
        }
        observedWindow = nil
        panel = nil
        lastSize = .zero
    }

    /// 面板定位与尺寸（全部【屏幕坐标】）：
    /// - 高度 = 工具栏区域总高 − 12（上下各留 6pt 悬空，不贴顶）
    /// - 宽度 = Open/Search 按钮水平距离的 50%（下限 220）
    /// - 水平居中于两按钮中点；垂直居中于工具栏条（留白悬空）
    /// 按钮识别：toolTip（.help 设置）与 label 都查——SwiftUI toolbar item 的 label 常为空。
    private func position(_ panel: NSPanel, relativeTo window: NSWindow) {
        var openFrame: NSRect?
        var searchFrame: NSRect?

        if let toolbar = window.toolbar {
            for item in toolbar.items {
                guard let view = item.view, let vw = view.window else { continue }
                let id = (item.label + " " + (view.toolTip ?? "")).lowercased()
                // ⚠️ convert(bounds, to: nil) = 窗口坐标，必须经 convertToScreen 转屏幕坐标
                let r = vw.convertToScreen(view.convert(view.bounds, to: nil))
                if id.contains("open") {
                    openFrame = r
                } else if id.contains("search") {
                    searchFrame = r
                }
            }
        }

        let chromeH = max(32, window.frame.height - window.contentLayoutRect.height)
        let height = chromeH - 12
        let width: CGFloat
        let x: CGFloat
        let y: CGFloat

        if let o = openFrame, let s = searchFrame {
            width = max(220, (s.midX - o.midX) * 0.5)
            x = (o.midX + s.midX) / 2 - width / 2
        } else {
            // 回退：窗口水平居中
            let wf = window.frame
            width = max(220, min(wf.width * 0.4, 520))
            x = wf.midX - width / 2
        }
        // 垂直：工具栏条内居中，上下各留 (chromeH - height)/2 = 6pt
        y = window.frame.maxY - chromeH + (chromeH - height) / 2

        // 尺寸缓存：拖动/缩放时尺寸不变则跳过 setContentSize（避免反复布局卡顿）
        let size = NSSize(width: width, height: height)
        if size != lastSize {
            panel.setContentSize(size)
            lastSize = size
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
