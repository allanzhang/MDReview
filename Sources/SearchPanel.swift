import AppKit
import SwiftUI

/// 无边框面板必须能成为 key window，否则内部输入框无法聚焦（borderless 默认 canBecomeKey=false）。
@MainActor private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 浮动搜索面板：点击搜索按钮时，在 Open 与 Search 按钮之间悬空浮出一个
/// 无边框玻璃搜索框（Spotlight 式）。原窗口布局完全不变。
///
/// 实现要点（历史教训）：
/// - 面板作为【子窗口】挂到主窗口（addChildWindow）——系统自动跟随父窗口移动/缩放，
///   彻底解决此前 didMoveNotification 手动同步的「拖动不同步、卡顿」问题。
/// - 子窗口 setFrameOrigin 用的是【窗口坐标】（相对父窗口，左下原点），与按钮的
///   convert(bounds, to: nil) 同坐标系，无需 convertToScreen（屏幕坐标是飞出 bug 的根源）。
/// - 垂直：面板在工具栏条内居中且上下留白（悬空感），不再贴窗口顶。
@MainActor final class SearchPanelController {
    static let shared = SearchPanelController()

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?

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

        position(panel, relativeTo: window)
        // 子窗口：自动跟随父窗口移动/缩放，无需手动同步
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.parentWindow = window
    }

    func hide() {
        panel?.orderOut(nil)
        if let panel, let parent = parentWindow {
            parent.removeChildWindow(panel)
        }
        panel = nil
        parentWindow = nil
    }

    /// 面板定位与尺寸（全部用【窗口坐标】，与按钮 convert(to: nil) 同坐标系）：
    /// - 高度 = 工具栏区域总高 − 12（上下各留 6pt 悬空，不贴顶）
    /// - 宽度 = Open/Search 按钮水平距离的 50%（下限 220）
    /// - 水平居中于两按钮中点；垂直居中于工具栏条（留白悬空）
    /// 按钮识别：toolTip（.help 设置）与 label 都查——SwiftUI toolbar item 的 label 常为空。
    private func position(_ panel: NSPanel, relativeTo window: NSWindow) {
        var openX: CGFloat?
        var searchX: CGFloat?

        if let toolbar = window.toolbar {
            for item in toolbar.items {
                guard let view = item.view else { continue }
                let id = (item.label + " " + (view.toolTip ?? "")).lowercased()
                // convert(bounds, to: nil) = 窗口坐标（左下原点），与子窗口 setFrameOrigin 一致
                let r = view.convert(view.bounds, to: nil)
                if id.contains("open") {
                    openX = r.midX
                } else if id.contains("search") {
                    searchX = r.midX
                }
            }
        }

        let chromeH = max(32, window.frame.height - window.contentLayoutRect.height)
        let height = chromeH - 12
        let width: CGFloat
        let x: CGFloat
        let y: CGFloat

        if let openX, let searchX {
            width = max(220, (searchX - openX) * 0.5)
            x = (openX + searchX) / 2 - width / 2
        } else {
            // 回退：窗口水平居中，工具栏条底部对齐
            width = max(220, min(window.frame.width * 0.4, 520))
            x = (window.frame.width - width) / 2
        }
        // 垂直：工具栏条内居中，上下各留 (chromeH - height)/2 = 6pt
        y = window.contentLayoutRect.height + (chromeH - height) / 2

        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
