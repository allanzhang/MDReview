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
                // 外观联动走 AppKit 层 NSApp.appearance（比 preferredColorScheme 稳定，
                // 避免 macOS 26 上 NavigationSplitView 布局动画时强制外观回退/闪烁）
                .modifier(WindowAppearanceModifier(mode: doc.appearance))
        }
        .windowResizability(.contentSize)
        .commands { AppCommands() }
    }
}

/// 菜单命令：补齐 File / View 标准命令；不提供 New Window / Tab（第一版不支持 Tab）。
private struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { postMenuAction(.openPanel) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open in External Editor…") { postMenuAction(.openInExternalEditor) }
                .keyboardShortcut("e", modifiers: .command)
            Divider()
            Menu("Export") {
                Button("Export as HTML…") { postMenuAction(.exportHTML) }
                Button("Export as PDF…") { postMenuAction(.exportPDF) }
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") { postMenuAction(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("Toggle Source / Rendered") { postMenuAction(.toggleSource) }
            Divider()
            Menu("Appearance") {
                Button("Follow System") { postMenuAction(.appearanceSystem) }
                Button("Light") { postMenuAction(.appearanceLight) }
                Button("Dark") { postMenuAction(.appearanceDark) }
            }
        }
    }
}

/// 菜单动作：经 NotificationCenter 转发给 ContentView 处理（单窗口场景简单可靠）。
enum MenuAction: String {
    case openPanel, toggleSidebar, toggleSource
    case appearanceSystem, appearanceLight, appearanceDark
    case exportHTML, exportPDF, openInExternalEditor
}

extension Notification.Name {
    static let mdreviewMenuAction = Notification.Name("mdreview.menuAction")
}

private func postMenuAction(_ action: MenuAction) {
    NotificationCenter.default.post(name: .mdreviewMenuAction, object: action)
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
        // 第一版不支持 Tab：显式关闭自动窗口标签，菜单不出现 New Tab / 标签栏等命令
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first {
            DocState.shared.open(u)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
