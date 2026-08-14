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
        .windowResizability(.contentSize)
    }
}

/// AppKit 层窗口外观控制：手动切亮/暗时设置 NSWindow.appearance（整窗含侧栏/工具栏跟随），
/// system 模式传 nil 跟随系统。WebView 内容由 applyAppearance（JS）同步。
struct WindowAppearanceModifier: ViewModifier {
    let mode: AppearanceMode

    func body(content: Content) -> some View {
        content.background(WindowAccessor { window in
            switch mode {
            case .system:
                window.appearance = nil
            case .light:
                window.appearance = NSAppearance(named: .aqua)
            case .dark:
                window.appearance = NSAppearance(named: .darkAqua)
            }
        })
    }
}

/// 从 SwiftUI 视图树获取所属 NSWindow（零尺寸背景视图，不影响布局）。
private struct WindowAccessor: NSViewRepresentable {
    let onSet: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onSet(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onSet(w) } }
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
