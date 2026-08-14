import Foundation
import SwiftUI

/// 全局文档状态：当前打开的 .md、原文、最近文件列表、大纲显隐。
/// 用单例是因为 AppDelegate 的 openURLs 也需要写入同一份状态。
@MainActor final class DocState: ObservableObject {
    static let shared = DocState()

    @Published var url: URL?
    @Published var rawText: String = ""
    @Published var recent: [URL] = []
    @Published var showOutline = true
    /// 侧边栏显隐（用于 NavigationSplitView columnVisibility 绑定）。
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// 渲染 / 源码 只读切换。
    @Published var showSource = false

    private let recentKey = "mdreview.recent"
    private let recentMax = 30

    init() {
        loadRecent()
    }

    func open(_ url: URL) {
        guard url.pathExtension.lowercased() == "md" ||
              url.pathExtension.lowercased() == "markdown" else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            self.rawText = text
            self.url = url
            if let idx = recent.firstIndex(of: url) { recent.remove(at: idx) }
            recent.insert(url, at: 0)
            if recent.count > recentMax { recent.removeLast() }
            saveRecent()
        } catch {
            self.rawText = "// 无法读取文件：\n\(error.localizedDescription)"
            self.url = url
        }
    }

    /// 从 UserDefaults 恢复最近文件（路径可能因文件被移动而失效，故做一次可达性过滤）。
    private func loadRecent() {
        guard let arr = UserDefaults.standard.array(forKey: recentKey) as? [String] else { return }
        recent = arr.compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveRecent() {
        let arr = recent.map { $0.path }
        UserDefaults.standard.set(arr, forKey: recentKey)
    }
}
