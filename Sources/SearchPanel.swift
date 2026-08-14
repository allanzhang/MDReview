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
/// - 拖动/缩放同步：**didMoveNotification 只在拖动结束才触发，不能做实时跟随**，
///   故拖动期间用 eventTracking 模式 60Hz 定时器实时重定位（平时不触发、零开销）；
///   didMove/didResize 监听做收尾与缩放同步。【尺寸缓存】——移动时不再反复
///   setContentSize 触发布局，只 setFrameOrigin，保证拖动流畅。
/// - 垂直：直接量 Open/Search 按钮视图的实际坐标——面板高度 = 按钮背景高度，
///   垂直居中于按钮行（不猜 chrome，不贴窗口顶；标题栏/工具栏高度随系统/外观变化，
///   猜 chrome 正是此前"高度对不上、不居中"的根因）。
@MainActor final class SearchPanelController {
    static let shared = SearchPanelController()

    private var panel: NSPanel?
    private weak var observedWindow: NSWindow?
    /// 拖动实时跟随定时器：只挂在 eventTracking 模式，拖动/缩放期间才触发。
    private var trackingTimer: Timer?
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
        startTracking(window)
        // 工具栏可能在面板刚显示时尚未完成布局，稍后重测一次按钮坐标，
        // 避免首次呼出时量到 0 尺寸而回退到 chrome 估算。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak panel, weak window] in
            guard let self, let panel, let window, self.panel === panel, panel.isVisible else { return }
            self.position(panel, relativeTo: window)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let w = observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: w)
        }
        observedWindow = nil
        panel = nil
        lastSize = .zero
    }

    /// 面板定位与尺寸（全部【屏幕坐标】）：
    /// - 高度 = Open/Search 按钮视图的实际高度（即按钮背景高度，直接量按钮）
    /// - 宽度 = Open/Search 按钮水平距离的 50%（下限 220）
    /// - 水平居中于两按钮中点；垂直居中于按钮行（不再贴窗口顶）
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
            // 回退：量不到按钮时保持旧的 chrome 估算
            let chromeH = max(32, window.frame.height - window.contentLayoutRect.height)
            height = chromeH
            y = window.frame.maxY - chromeH
        }

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

    /// 实时跟随：NSWindow.didMoveNotification 只在拖动结束（或停顿约半秒）才发送，
    /// 观察者方案在拖动过程中面板会停在原地、松手才跳过去（用户反馈的"不同步"）。
    /// 改为在 eventTracking 模式下跑 60Hz 定时器，拖动期间每帧重定位；
    /// 平时（default 模式）定时器不触发，无额外开销。
    private func startTracking(_ window: NSWindow) {
        trackingTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(trackingTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .eventTracking)
        trackingTimer = timer
    }

    @objc private func trackingTick(_ timer: Timer) {
        guard let window = observedWindow, let panel, isVisible else {
            timer.invalidate()
            return
        }
        position(panel, relativeTo: window)
    }

    @objc private func windowFrameChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, let panel, isVisible else { return }
        position(panel, relativeTo: window)
    }
}
