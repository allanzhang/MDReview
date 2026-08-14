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
/// 实现要点：
/// - **childWindow（AppKit 主流做法）**：`addChildWindow(panel, ordered: .above)`，
///   子窗口随父窗口移动**原生同步**，拖动无需任何监听/定时器。
///   子窗口**不设独立层级**（`level`/`isFloatingPanel` 是独立浮层用法，child 应跟随父窗口；
///   child+borderless+独立层级在 macOS 26 上偶发不显示）。
/// - 定位统一用【屏幕坐标】：按钮 convert(bounds, to: nil) 是窗口坐标，必须经
///   convertToScreen 转换后 setFrameOrigin。
/// - 缩放时保留 didResize 观察者：窗口变宽/变窄会使工具栏按钮重排（Open↔Search
///   中点水平移动），需重测面板位置；拖动移动由 childWindow 原生跟随，不需要监听。
/// - **模糊保持**：behindWindow 模糊只在窗口 active（key/main）时渲染，点击主窗口空白处
///   会让面板失焦 → 模糊掉。面板打开期间失焦即抢回 key（应用前台且非主动关闭时），
///   模糊保持到主动关闭；应用切后台不抢（重进前台时恢复）。
/// - 【尺寸缓存】——重定位时尺寸不变则跳过 setContentSize，只 setFrameOrigin。
/// - 垂直：直接量 Open/Search 按钮视图的实际坐标——面板高度 = 按钮背景高度，
///   垂直居中于按钮行（标题栏/工具栏高度随系统/外观变化，不猜 chrome）。
@MainActor final class SearchPanelController {
    static let shared = SearchPanelController()

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    /// 正在主动关闭中：hide() 期间的失焦通知不抢 key。
    private var isClosing = false
    /// 尺寸缓存：位置不变时跳过 setContentSize（避免反复布局卡顿）。
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
        // ⚠️ 子窗口不设 level / isFloatingPanel：跟随父窗口层级（独立层级在 macOS 26 偶发不显示）
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // 阴影由 SwiftUI SearchBar 自身绘制
        panel.hidesOnDeactivate = false
        panel.contentView = host

        // 子窗口：随父窗口移动/缩放自动同步（主流做法，零监听零定时器）
        window.addChildWindow(panel, ordered: .above)
        lastSize = .zero
        position(panel, relativeTo: window)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        parentWindow = window

        isClosing = false
        // 面板失焦（点击主窗口空白处）时抢回 key：behindWindow 模糊只在窗口 active 时渲染，
        // 失焦会让模糊掉。主动关闭（hide）与应用切后台时不抢。
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )

        observeResize(window)
        // 工具栏可能在面板刚显示时尚未完成布局，稍后重测一次按钮坐标，
        // 避免首次呼出时量到 0 尺寸而回退到 chrome 估算。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak panel, weak window] in
            guard let self, let panel, let window, self.panel === panel, panel.isVisible else { return }
            self.position(panel, relativeTo: window)
        }
    }

    func hide() {
        isClosing = true
        if let panel, let window = parentWindow {
            window.removeChildWindow(panel)
        }
        panel?.orderOut(nil)
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
        if let window = parentWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: window)
        }
        parentWindow = nil
        panel = nil
        lastSize = .zero
    }

    /// 面板定位与尺寸（全部【屏幕坐标】）：
    /// - 高度 = Open/Search 按钮视图的实际高度（即按钮背景高度，直接量按钮）
    /// - 宽度 = Open/Search 按钮水平距离的 50%（下限 220）
    /// - 水平居中于两按钮中点；垂直居中于按钮行（不贴窗口顶）
    /// 按钮识别：toolTip（.help 设置）与 label 都查——SwiftUI toolbar item 的 label 常为空。
    private func position(_ panel: NSPanel, relativeTo window: NSWindow) {
        var openFrame: NSRect?
        var searchFrame: NSRect?
        var rowTop = -CGFloat.greatestFiniteMagnitude
        var rowBottom = CGFloat.greatestFiniteMagnitude
        var hasButtons = false

        if let toolbar = window.toolbar {
            for item in toolbar.items {
                guard let view = item.view, let vw = view.window else { continue }
                let id = (item.label + " " + (view.toolTip ?? "")).lowercased()
                // ⚠️ convert(bounds, to: nil) = 窗口坐标，必须经 convertToScreen 转屏幕坐标
                let r = vw.convertToScreen(view.convert(view.bounds, to: nil))
                guard r.width > 0, r.height > 0 else { continue }
                let isOpen = id.contains("open")
                let isSearch = id.contains("search")
                if isOpen {
                    openFrame = r
                }
                if isSearch {
                    searchFrame = r
                }
                if isOpen || isSearch {
                    hasButtons = true
                    rowTop = max(rowTop, r.maxY)
                    rowBottom = min(rowBottom, r.minY)
                }
            }
        }

        let width: CGFloat
        let x: CGFloat

        if let o = openFrame, let s = searchFrame {
            width = max(220, (s.midX - o.midX) * 0.5)
            x = (o.midX + s.midX) / 2 - width / 2
        } else {
            // 回退：窗口水平居中
            let wf = window.frame
            width = max(220, min(wf.width * 0.4, 520))
            x = wf.midX - width / 2
        }

        let height: CGFloat
        let y: CGFloat
        if hasButtons {
            // 按钮行高 = 按钮视图上下沿之差；垂直中心 = 按钮行中心
            height = max(24, rowTop - rowBottom)
            y = (rowTop + rowBottom) / 2 - height / 2
        } else {
            // 回退：量不到按钮时按窗口尺寸估算
            let chromeH = max(32, window.frame.height - window.contentLayoutRect.height)
            height = chromeH
            y = window.frame.maxY - chromeH
        }

        // 尺寸缓存：重定位时尺寸不变则跳过 setContentSize（避免反复布局卡顿）
        let size = NSSize(width: width, height: height)
        if size != lastSize {
            panel.setContentSize(size)
            lastSize = size
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 仅窗口缩放时重测面板位置：窗口变宽/变窄会让工具栏按钮重排（Open↔Search
    /// 中点水平移动），childWindow 只跟随窗口 frame，不会跟随按钮重排。
    /// 拖动移动无需监听——子窗口随父窗口原生同步。
    private func observeResize(_ window: NSWindow) {
        if let w = parentWindow, w !== window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: w)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification, object: window
        )
    }

    @objc private func windowDidResize(_ note: Notification) {
        guard let window = note.object as? NSWindow, let panel, isVisible else { return }
        position(panel, relativeTo: window)
    }

    /// behindWindow 模糊只在窗口 active（key/main）时渲染：点击主窗口空白处会让主窗口成为
    /// key、面板失焦 → 模糊掉。面板打开期间失焦就抢回 key 保持模糊，直到主动关闭。
    @objc private func panelDidResignKey(_ note: Notification) {
        guard !isClosing, NSApp.isActive, let panel, isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 应用从后台切回时（hidesOnDeactivate=false 面板仍在但已失焦），重夺 key 恢复模糊。
    @objc private func appDidBecomeActive(_ note: Notification) {
        guard !isClosing, let panel, isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }
}
