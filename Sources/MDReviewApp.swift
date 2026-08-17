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
@MainActor private struct AppCommands: Commands {
    @ObservedObject private var doc = DocState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button { postMenuAction(.openPanel) } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            Menu {
                ForEach(doc.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { postMenuAction(.openRecent(url)) }
                }
                if !doc.recent.isEmpty {
                    Divider()
                    Button("Clear Menu") { postMenuAction(.clearRecent) }
                }
            } label: {
                Label("Open Recent", systemImage: "clock.arrow.circlepath")
            }
            Button { postMenuAction(.openInExternalEditor) } label: {
                Label("Open in External Editor…", systemImage: "pencil.and.outline")
            }
            .keyboardShortcut("e", modifiers: .command)
            Divider()
            Menu {
                Button { postMenuAction(.exportHTML) } label: {
                    Label("Export as HTML…", systemImage: "doc.richtext")
                }
                Button { postMenuAction(.exportPDF) } label: {
                    Label("Export as PDF…", systemImage: "doc")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        CommandGroup(after: .toolbar) {
            Button { postMenuAction(.toggleSidebar) } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button { postMenuAction(.toggleSource) } label: {
                Label("Toggle Source / Rendered", systemImage: "doc.richtext")
            }
            Divider()
            Menu {
                Button { postMenuAction(.appearanceSystem) } label: {
                    Label("Follow System", systemImage: "circle.lefthalf.filled")
                }
                Button { postMenuAction(.appearanceLight) } label: {
                    Label("Light", systemImage: "sun.max")
                }
                Button { postMenuAction(.appearanceDark) } label: {
                    Label("Dark", systemImage: "moon")
                }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
        }
    }
}

/// 菜单动作：经 NotificationCenter 转发给 ContentView 处理（单窗口场景简单可靠）。
enum MenuAction {
    case openPanel, toggleSidebar, toggleSource
    case appearanceSystem, appearanceLight, appearanceDark
    case exportHTML, exportPDF, openInExternalEditor, revealInFinder
    case openRecent(URL), clearRecent
}

extension Notification.Name {
    static let mdreviewMenuAction = Notification.Name("mdreview.menuAction")
    static let mdreviewSourceScroll = Notification.Name("mdreview.sourceScroll")
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
            // 系统（Finder 双击）打开的文件优先，启动时不再自动恢复上次文档
            DocState.shared.didOpenViaSystem = true
            DocState.shared.open(u)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}
