import SwiftUI

@main
struct MDReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var doc = DocState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(doc)
                // 外观联动：手动切亮/暗时整个窗口（侧栏/工具栏/搜索条）跟随，
                // system 模式传 nil 跟随系统；WebView 内容由 applyAppearance 同步
                .preferredColorScheme(doc.appearance.colorScheme)
        }
        .windowResizability(.contentSize)
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
