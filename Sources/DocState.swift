import Foundation
import SwiftUI

/// 外观模式：跟随系统 / 强制亮 / 强制暗（默认跟随系统，可手动切换）。
enum AppearanceMode: String {
    case system = "system"
    case light = "light"
    case dark = "dark"
}

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
    /// 外观模式（跟随系统/强制亮/强制暗），UserDefaults 持久化。
    @Published var appearance: AppearanceMode = .system

    private let recentKey = "mdreview.recent"
    private let appearanceKey = "mdreview.appearance"
    private let recentMax = 30
    /// 当前文件系统监听（外部编辑器保存后自动重载，AI 工作流刚需）。
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?
    /// 异步打开竞态防护：记录最近一次请求的 URL，读盘完成时若已被新请求覆盖则丢弃旧结果。
    private var pendingOpenURL: URL?

    init() {
        loadRecent()
        appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }

    /// 设置外观模式并持久化（渲染层经 renderer.applyAppearance 即时生效，无需重载）。
    func setAppearance(_ mode: AppearanceMode) {
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceKey)
    }

    func open(_ url: URL) {
        guard url.pathExtension.lowercased() == "md" ||
              url.pathExtension.lowercased() == "markdown" else { return }
        startMonitoring(url)
        pendingOpenURL = url
        // 后台读盘避免大文件阻塞主线程；完成回调经 pendingOpenURL 比对丢弃过期结果
        Task.detached(priority: .userInitiated) { [weak self] in
            var text: String?
            var errorMsg: String?
            do { text = try String(contentsOf: url, encoding: .utf8) }
            catch { errorMsg = error.localizedDescription }
            await MainActor.run {
                guard let self, self.pendingOpenURL == url else { return }  // 已被更新的打开请求覆盖
                self.pendingOpenURL = nil
                if let text {
                    self.rawText = text
                    self.url = url
                    if let idx = self.recent.firstIndex(of: url) { self.recent.remove(at: idx) }
                    self.recent.insert(url, at: 0)
                    if self.recent.count > self.recentMax { self.recent.removeLast() }
                    self.saveRecent()
                } else {
                    self.rawText = "// Cannot read file:\n\(errorMsg ?? "Unknown error")"
                    self.url = url
                }
            }
        }
    }

    /// 建立对当前文件的磁盘监听（.write/.delete/.rename），外部保存后防抖重载。
    private func startMonitoring(_ url: URL) {
        fileMonitor?.cancel()
        fileMonitor = nil
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }

    /// 防抖：外部编辑器可能连续写入，400ms 内合并为一次重载。
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func reloadFromDisk() {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 文件被删除/重命名：停止监听，避免持续报错
            fileMonitor?.cancel()
            fileMonitor = nil
            return
        }
        // 后台读盘避免大文件热更新阻塞主线程
        Task.detached(priority: .utility) { [weak self] in
            let text = try? String(contentsOf: url, encoding: .utf8)
            await MainActor.run {
                guard let self, let text, text != self.rawText else { return }
                self.rawText = text
            }
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
