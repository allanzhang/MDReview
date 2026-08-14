import AppKit
import SwiftUI

@main
struct MDReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            WindowRoot()
        }
        .windowResizability(.contentSize)
        .commands { ViewMenuCommands() }
    }
}

/// View 菜单提供 New Tab 入口：打开一个独立文档的新窗口/Tab
/// （每个窗口独立 DocState，见 WindowRoot）。系统 File 菜单另有 ⌘N New Window；
/// 启用 allowsAutomaticWindowTabbing 后 ⌘T/Window 菜单的 Tab 管理由系统提供。
private struct ViewMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("New Tab") { openWindow(id: "main") }
        }
    }
}

/// 每个窗口（Tab）持有自己的一份 DocState：@StateObject 放在 WindowGroup 内容闭包内，
/// 每个窗口实例化一次，多窗口/Tab 各自独立文档，互不串文件。
@MainActor
private struct WindowRoot: View {
    @StateObject private var doc = DocState()

    var body: some View {
        ContentView()
            .environmentObject(doc)
            // 外观联动走 AppKit 层 NSApp.appearance（比 preferredColorScheme 稳定，
            // 避免 macOS 26 上 NavigationSplitView 布局动画时强制外观回退/闪烁）
            .modifier(WindowAppearanceModifier(mode: doc.appearance))
            // 窗口成为 key 时把本窗口 doc 注册为活动文档（Finder 打开路由用）
            .background(WindowFocusTracker(doc: doc))
    }
}

/// 感知窗口成为 key：把该窗口的 DocState 注册为「活动文档」，供 AppDelegate 的
/// application(_:open:)（Finder 双击 .md）路由到前台窗口。
private struct WindowFocusTracker: NSViewRepresentable {
    let doc: DocState

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.doc = doc
        context.coordinator.view = v
        DispatchQueue.main.async { context.coordinator.setup() }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var view: NSView?
        var doc: DocState?
        private var isObserving = false

        func setup() {
            guard let w = view?.window, let doc else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: w
            )
            isObserving = true
            if w.isKeyWindow { DocState.activate(doc) }
        }

        @objc private func windowDidBecomeKey(_ note: Notification) {
            guard let doc else { return }
            DocState.activate(doc)
        }

        deinit {
            if isObserving { NotificationCenter.default.removeObserver(self) }
        }
    }
}

/// 应用级外观控制：设置 NSApp.appearance（AppKit 广播外观变化，工具栏等系统组件会刷新）。
struct WindowAppearanceModifier: ViewModifier {
    let mode: AppearanceMode

    func body(content: Content) -> some View {
        content
            .onChange(of: mode) { _, newMode in Self.apply(newMode) }
            .onAppear { Self.apply(mode) }
    }

    private static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启用系统窗口 Tab：File 菜单出现 New Tab（⌘T），窗口可合并成 Tab、
        // 每个 Tab 是独立窗口（各自独立 DocState，见 WindowRoot）。
        NSWindow.allowsAutomaticWindowTabbing = true
        // 关闭 Tab 后：若某个 Tab 组只剩一个窗口，把它移出组、恢复单视图
        // （保证所有 Tab 可逐个关闭，关闭到最后一个时自然退出多 Tab 模式）。
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    /// 关闭任意窗口/Tab 后：某个 Tab 组只剩一个窗口时，把该窗口移出 Tab 组并
    /// 恢复跟随系统偏好（tabbingMode .automatic），标签栏随之消失、回到单视图。
    @objc private func windowDidClose(_ note: Notification) {
        DispatchQueue.main.async {
            for w in NSApp.windows where w.isVisible {
                guard let group = w.tabGroup, group.windows.count == 1 else { continue }
                group.removeWindow(w)
                w.tabbingMode = .automatic
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        // 路由到前台窗口的文档；冷启动窗口未就绪时暂存，窗口出现后消费（DocState.activate）
        if let active = DocState.active {
            active.open(u)
        } else {
            DocState.pendingOpenURL = u
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
