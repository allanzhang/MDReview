import AppKit
import Foundation
import SwiftUI

/// 外观模式：跟随系统 / 强制亮 / 强制暗（默认跟随系统，可手动切换）。
enum AppearanceMode: String {
    case system = "system"
    case light = "light"
    case dark = "dark"

    /// 映射到 SwiftUI 外观（nil = 跟随系统）。用于让整个窗口（侧栏/工具栏/搜索条）
    /// 与 WebView 内容在手动切换时保持一致，避免「内容变暗、外壳仍亮」的割裂。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 全局文档状态：当前打开的 .md、原文、最近文件列表、大纲显隐。
/// 单例：AppDelegate 的 openURLs 与所有视图共享同一份状态。
@MainActor final class DocState: ObservableObject {
    static let shared = makeApplicationState()

    static func makeApplicationState(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = { SystemLanguage.preferredLanguages() }
    ) -> DocState {
        // 未完成版本可能写入过进程级语言覆盖；必须在首次读取系统语言前清理。
        defaults.removeObject(forKey: "AppleLanguages")
        return DocState(defaults: defaults, preferredLanguages: preferredLanguages)
    }

    @Published var url: URL?
    @Published var rawText: String = ""
    @Published var recent: [URL] = []
    @Published var showOutline = true
    /// 侧边栏显隐（用于 NavigationSplitView columnVisibility 绑定）。
    @Published var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet { UserDefaults.standard.set(columnVisibility != .detailOnly, forKey: sidebarKey) }
    }
    /// 渲染 / 源码 只读切换。
    @Published var showSource = false
    /// 外观模式（跟随系统/强制亮/强制暗）。默认始终为 system（不持久化手动选择，
    /// 重启回到跟随系统）；手动切换用于临时覆盖，再次点击回到 system。
    @Published var appearance: AppearanceMode = .system
    /// 阅读区字号缩放（0.8×~1.5×，步进 0.1）。不持久化，与外观"临时覆盖"语义一致。
    @Published var fontSizeScale: Double = 1.0
    /// 界面语言：跟随系统 / 中文 / English。手动选择持久化，默认跟随系统。
    @Published var language: AppLanguage = .system {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
            updateResolvedLanguage()
        }
    }
    /// 当前实际显示语言。与持久化的选择模式分离，以便系统语言变化时主动发布刷新。
    @Published private(set) var resolvedLanguage: AppLanguage = .english
    /// 当前文件在磁盘上已有更新，等待用户手动刷新。
    @Published var hasPendingFileUpdate = false

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private let recentKey = "mdreview.recent"
    private let recentMax = 30
    private let lastUrlKey = "mdreview.lastUrl"
    private let sidebarKey = "mdreview.sidebarVisible"
    /// 当前文件系统监听（外部编辑器保存后提示用户刷新）。
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var updateFlagWorkItem: DispatchWorkItem?
    /// 异步打开竞态防护：记录最近一次请求的 URL，读盘完成时若已被新请求覆盖则丢弃旧结果。
    private var pendingOpenURL: URL?
    /// 启动时是否已由系统打开文件（Finder 双击）：若是则不再自动恢复上次文档。
    var didOpenViaSystem = false
    /// 上次打开文档的路径（启动恢复用；文件已不存在则返回 nil）。
    var lastDocumentURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: lastUrlKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: path) ? url : nil
    }

    init(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = { SystemLanguage.preferredLanguages() }
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let storedLanguage = AppLanguage.load(
            from: defaults.string(forKey: AppLanguage.defaultsKey)
        )
        language = storedLanguage
        resolvedLanguage = storedLanguage.resolved(
            preferredLanguages: preferredLanguages()
        )
        loadRecent()
        if UserDefaults.standard.object(forKey: sidebarKey) as? Bool == false {
            columnVisibility = .detailOnly
        }
    }

    var locale: Locale {
        resolvedLanguage.locale
    }

    /// 语言菜单入口：重复选择当前项时保持文档、滚动位置和状态不变。
    func setLanguage(_ newValue: AppLanguage) {
        guard language != newValue else { return }
        language = newValue
    }

    /// 系统语言变化时仅刷新 Follow System；手动中文/英文保持不变。
    func refreshSystemLanguage() {
        guard language == .system else { return }
        updateResolvedLanguage()
    }

    private func updateResolvedLanguage() {
        let newValue = language.resolved(preferredLanguages: preferredLanguages())
        guard newValue != resolvedLanguage else { return }
        resolvedLanguage = newValue
        NotificationCenter.default.post(name: .mdreviewLanguageChanged, object: newValue)
    }

    /// 外观按钮点击：System → 切到当前系统外观的反面（临时覆盖）；手动 → 回到 System。
    /// 不持久化手动选择，重启后始终为跟随系统。
    func toggleAppearance() {
        switch appearance {
        case .system:
            let isSystemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            appearance = isSystemDark ? .light : .dark
        case .light, .dark:
            appearance = .system
        }
    }

    func open(_ url: URL) {
        guard url.pathExtension.lowercased() == "md" ||
              url.pathExtension.lowercased() == "markdown" else { return }
        clearPendingFileUpdate()
        startMonitoring(url)
        // recent 与 lastUrl 在发起打开时就记，不放进读盘回调：重新打开当前文档时回调会被
        // pendingOpenURL 守卫丢弃，清空历史后只剩一篇时再点它，列表和启动恢复都回不来。
        touchRecent(url)
        UserDefaults.standard.set(url.path, forKey: lastUrlKey)
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
                } else {
                    let message = errorMsg ?? L10n.string("Unknown error", language: self.resolvedLanguage)
                    self.rawText = "// " + L10n.format("Cannot read file: %@", language: self.resolvedLanguage, message)
                    self.url = url
                }
            }
        }
    }

    /// 把文档记入最近列表并置顶，超过上限丢弃最旧一条。
    private func touchRecent(_ url: URL) {
        if let idx = recent.firstIndex(of: url) { recent.remove(at: idx) }
        recent.insert(url, at: 0)
        if recent.count > recentMax { recent.removeLast() }
        saveRecent()
    }

    /// 建立对当前文件的磁盘监听（.write/.delete/.rename），外部保存后防抖标记更新。
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
            Task { @MainActor in
                guard let self, self.url == url else { return }
                // 编辑器常用原子替换保存；重新打开 fd，避免旧 inode 的监听在首次事件后失效。
                self.startMonitoring(url)
                self.scheduleUpdateFlag()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }

    /// 防抖：外部编辑器可能连续写入，400ms 内合并为一次更新标记。
    private func scheduleUpdateFlag() {
        updateFlagWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.markPendingUpdate() }
        }
        updateFlagWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func markPendingUpdate() {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 文件被删除/重命名：停止监听，避免持续报错
            fileMonitor?.cancel()
            fileMonitor = nil
            return
        }
        hasPendingFileUpdate = true
    }

    /// 清理待更新标记，同时取消尚未触发的防抖任务，避免旧文件事件误标当前文件。
    func clearPendingFileUpdate() {
        updateFlagWorkItem?.cancel()
        updateFlagWorkItem = nil
        hasPendingFileUpdate = false
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

    /// 从最近列表移除（右键菜单）。移走的是启动恢复目标时一并清除，
    /// 否则列表删空后重启仍会打开它。
    func removeRecent(_ url: URL) {
        recent.removeAll { $0 == url }
        saveRecent()
        if UserDefaults.standard.string(forKey: lastUrlKey) == url.path {
            UserDefaults.standard.removeObject(forKey: lastUrlKey)
        }
    }

    /// 清空最近列表（Open Recent 菜单）。同时清除启动恢复用的 lastUrl，
    /// 否则重启时 restoreLastDocument 会把刚清掉的最后一篇重新打开。
    func clearRecent() {
        recent.removeAll()
        saveRecent()
        UserDefaults.standard.removeObject(forKey: lastUrlKey)
    }

    /// 用外部编辑器打开指定文件：优先 Cursor / VSCode，未检测到则退回系统默认关联应用。
    func openInExternalEditor(_ url: URL) {
        let userApps = NSHomeDirectory() + "/Applications"
        let candidates = [
            "/Applications/Cursor.app",
            "/Applications/Visual Studio Code.app",
            userApps + "/Cursor.app",
            userApps + "/Visual Studio Code.app"
        ]
        var appURL: URL?
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { appURL = URL(fileURLWithPath: c); break }
        }
        if let appURL {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
