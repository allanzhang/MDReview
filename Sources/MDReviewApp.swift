import SwiftUI

@main
struct MDReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var doc = DocState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(doc)
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
