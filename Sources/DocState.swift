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
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            self.rawText = text
            self.url = url
            if let idx = recent.firstIndex(of: url) { recent.remove(at: idx) }
            recent.insert(url, at: 0)
            if recent.count > recentMax { recent.removeLast() }
            saveRecent()
        } catch {
            self.rawText = "// Cannot read file:\n\(error.localizedDescription)"
            self.url = url
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
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text != rawText { rawText = text }
        } catch {
            // 读取失败（编辑器可能正在写入中途）：忽略，等下一次事件
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
