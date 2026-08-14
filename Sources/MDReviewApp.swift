import AppKit
import SwiftUI

@main
struct MDReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var doc = DocState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(doc)
                // 外观联动走 AppKit 层 NSWindow.appearance（比 preferredColorScheme 稳定，
                // 避免 macOS 26 上 NavigationSplitView 布局动画时强制外观回退/闪烁）
                .modifier(WindowAppearanceModifier(mode: doc.appearance))
        }
        // 隐藏标题栏：内容延伸至窗口顶部，搜索框等悬浮层可与窗口顶边齐平
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// 应用级外观控制：设置 NSApp.appearance（AppKit 广播外观变化，工具栏等系统组件会刷新）。
/// 相比 preferredColorScheme：不受 SwiftUI 布局动画影响（不会回退闪烁）；
/// 相比 NSWindow.appearance：应用级广播会强制 NSToolbar 重绘按钮，避免"图标残留亮色看不清"。
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
    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first {
            DocState.shared.open(u)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
