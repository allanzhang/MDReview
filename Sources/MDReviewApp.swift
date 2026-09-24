import AppKit
import SwiftUI
import Combine

enum MainWindow {
    static let autosaveName = "MDReviewMainWindow"
}

@main
struct MDReviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// 菜单只订阅菜单自己的依赖（语言模式 / 实际语言 / 最近文件），
    /// 不再直接依赖 DocState：否则 DocState 任何字段变化都会重建整份菜单。
    @StateObject private var menu = AppMenuModel(doc: .shared)

    var body: some Scene {
        Window("MDReview", id: "main") {
            RootView()
        }
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentSize)
        .commands {
            AppCommands(
                resolvedLanguage: menu.resolvedLanguage,
                selectedLanguage: menu.selectedLanguage,
                recent: menu.recent,
                setLanguage: { menu.setLanguage($0) }
            )
        }
    }
}

/// 根视图：承载 DocState 的环境注入与外观/语言联动。
/// App 层不再观察 DocState，菜单因此只在自身依赖变化时才重建。
@MainActor
private struct RootView: View {
    @ObservedObject private var doc = DocState.shared

    var body: some View {
        ContentView()
            .environmentObject(doc)
            .environment(\.locale, doc.locale)
            // 外观联动走 AppKit 层 NSApp.appearance（比 preferredColorScheme 稳定，
            // 避免 macOS 26 上 NavigationSplitView 布局动画时强制外观回退/闪烁）
            .modifier(WindowAppearanceModifier(mode: doc.appearance))
    }
}

/// 菜单依赖模型：只对外发布菜单真正读取的三样数据，且仅在值变化时发布。
@MainActor
final class AppMenuModel: ObservableObject {
    @Published private(set) var selectedLanguage: AppLanguage
    @Published private(set) var resolvedLanguage: AppLanguage
    @Published private(set) var recent: [URL]

    private let doc: DocState
    private var cancellables: Set<AnyCancellable> = []

    init(doc: DocState) {
        self.doc = doc
        selectedLanguage = doc.language
        resolvedLanguage = doc.resolvedLanguage
        recent = doc.recent

        doc.$language.sink { [weak self] value in
            guard let self, self.selectedLanguage != value else { return }
            self.selectedLanguage = value
        }.store(in: &cancellables)
        doc.$resolvedLanguage.sink { [weak self] value in
            guard let self, self.resolvedLanguage != value else { return }
            self.resolvedLanguage = value
        }.store(in: &cancellables)
        doc.$recent.sink { [weak self] value in
            guard let self, self.recent != value else { return }
            self.recent = value
        }.store(in: &cancellables)
    }

    func setLanguage(_ mode: AppLanguage) {
        doc.setLanguage(mode)
    }
}

/// 菜单命令：补齐 File / View 标准命令；固定单窗口，不提供 New Window / Tab。
@MainActor private struct AppCommands: Commands {
    let resolvedLanguage: AppLanguage
    let selectedLanguage: AppLanguage
    let recent: [URL]
    let setLanguage: (AppLanguage) -> Void

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.string("About MDReview", language: resolvedLanguage)) {
                AboutWindowController.shared.show()
            }
            Button(L10n.string("Check for Updates…", language: resolvedLanguage)) {
                AboutWindowController.shared.show()
                Task { @MainActor in
                    await UpdateManager.shared.checkForUpdates(manual: true)
                }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button { postMenuAction(.openPanel) } label: {
                Label(L10n.string("Open…", language: resolvedLanguage), systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
            Menu {
                ForEach(recent, id: \.self) { url in
                    Button(url.lastPathComponent) { postMenuAction(.openRecent(url)) }
                }
                if !recent.isEmpty {
                    Divider()
                    Button(L10n.string("Clear Menu", language: resolvedLanguage)) { postMenuAction(.clearRecent) }
                }
            } label: {
                Label(L10n.string("Open Recent", language: resolvedLanguage), systemImage: "clock.arrow.circlepath")
            }
            Button { postMenuAction(.openInExternalEditor) } label: {
                Label(L10n.string("Open in External Editor…", language: resolvedLanguage), systemImage: "pencil.and.outline")
            }
            .keyboardShortcut("e", modifiers: .command)
            Divider()
            Menu {
                Button { postMenuAction(.exportHTML) } label: {
                    Label(L10n.string("Export as HTML…", language: resolvedLanguage), systemImage: "doc.richtext")
                }
                Button { postMenuAction(.exportPDF) } label: {
                    Label(L10n.string("Export as PDF…", language: resolvedLanguage), systemImage: "doc")
                }
            } label: {
                Label(L10n.string("Export", language: resolvedLanguage), systemImage: "square.and.arrow.up")
            }
        }
        CommandGroup(after: .toolbar) {
            Button { postMenuAction(.search) } label: {
                Label(L10n.string("Find", language: resolvedLanguage), systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            Button { postMenuAction(.toggleSidebar) } label: {
                Label(L10n.string("Toggle Sidebar", language: resolvedLanguage), systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button { postMenuAction(.toggleSource) } label: {
                Label(L10n.string("Toggle Source / Rendered", language: resolvedLanguage), systemImage: "doc.richtext")
            }
            Divider()
            Menu {
                Button { postMenuAction(.appearanceSystem) } label: {
                    Label(L10n.string("Follow System", language: resolvedLanguage), systemImage: "circle.lefthalf.filled")
                }
                Button { postMenuAction(.appearanceLight) } label: {
                    Label(L10n.string("Light", language: resolvedLanguage), systemImage: "sun.max")
                }
                Button { postMenuAction(.appearanceDark) } label: {
                    Label(L10n.string("Dark", language: resolvedLanguage), systemImage: "moon")
                }
            } label: {
                Label(L10n.string("Appearance", language: resolvedLanguage), systemImage: "circle.lefthalf.filled")
            }
            Menu {
                languageMenuItem(.system)
                languageMenuItem(.chinese)
                languageMenuItem(.english)
            } label: {
                Label(L10n.string("Language", language: resolvedLanguage), systemImage: "globe")
            }
        }
        CommandGroup(replacing: .pasteboard) {
            Button(L10n.string("Copy", language: resolvedLanguage)) {
                NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
            }
            .keyboardShortcut("c", modifiers: .command)
            Button(L10n.string("Paste", language: resolvedLanguage)) {
                NSApp.sendAction(Selector(("paste:")), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: .command)
            Button(L10n.string("Select All", language: resolvedLanguage)) {
                NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil)
            }
            .keyboardShortcut("a", modifiers: .command)
        }
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .system:
            return L10n.string("Follow System", language: resolvedLanguage)
        case .chinese:
            return "中文"
        case .english:
            return "English"
        }
    }

    @ViewBuilder
    private func languageMenuItem(_ language: AppLanguage) -> some View {
        let title = languageTitle(language)
        Button {
            setLanguage(language)
        } label: {
            if selectedLanguage == language {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// 菜单动作：经 NotificationCenter 转发给 ContentView 处理（单窗口场景简单可靠）。
enum MenuAction {
    case openPanel, search, toggleSidebar, toggleSource
    case appearanceSystem, appearanceLight, appearanceDark
    case exportHTML, exportPDF, openInExternalEditor, revealInFinder
    case openRecent(URL), clearRecent
}

extension Notification.Name {
    static let mdreviewMenuAction = Notification.Name("mdreview.menuAction")
    static let mdreviewSourceScroll = Notification.Name("mdreview.sourceScroll")
    static let mdreviewSourceSearch = Notification.Name("mdreview.sourceSearch")
    static let mdreviewSourceSearchNext = Notification.Name("mdreview.sourceSearchNext")
    static let mdreviewSourceSearchPrev = Notification.Name("mdreview.sourceSearchPrev")
    static let mdreviewSourceGetSelection = Notification.Name("mdreview.sourceGetSelection")
    static let mdreviewSourceSelection = Notification.Name("mdreview.sourceSelection")
}

private func postMenuAction(_ action: MenuAction) {
    NotificationCenter.default.post(name: .mdreviewMenuAction, object: action)
}

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
    /// 防止"改写标题 → didChangeItem 通知 → 再改写"的自我递归。
    private var isLocalizingMainMenu = false
    /// 合并窗口：菜单结构变化会一次涌入几十条通知（SwiftUI 重建 Commands 时逐条加 item），
    /// 每条都全量改写主菜单会放大成上百次 O(菜单规模) 重写，实测把主线程堵死 7 秒。
    private var pendingMenuUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 第一版不支持 Tab：显式关闭自动窗口标签，菜单不出现 New Tab / 标签栏等命令
        NSWindow.allowsAutomaticWindowTabbing = false
        installTitlebarDrag()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange(_:)),
            name: .mdreviewLanguageChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemLocaleDidChange(_:)),
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuStructureDidChange(_:)),
            name: NSMenu.didAddItemNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        scheduleMainMenuUpdates()

        // 每次启动固定检查一次；失败静默，不阻塞文档打开。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await UpdateManager.shared.checkForUpdates(manual: false)
        }
    }

    /// 标题栏拖窗：窗口带 .fullSizeContentView，SwiftUI 内容一直铺到标题栏底下，
    /// 点在标题上时 NSThemeFrame 收不到事件，系统原生拖动失效。
    /// 命中问 NSThemeFrame（content 的父视图）而不是 contentView：
    /// 红绿灯、toolbar 是 themeFrame 的子视图且压在内容之上，themeFrame 命中它们；
    /// 标题文字没有 AppKit 视图挡着，会一路命中到 content 子树——只有这才代发拖动。
    /// 区域判定用 contentLayoutRect，不动任何布局。
    /// 方法在 @MainActor 的 AppDelegate 上，监视器闭包由此继承隔离，才能直接调 performDrag(with:)。
    private func installTitlebarDrag() {
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let window = event.window,
                  let content = window.contentView,
                  let theme = content.superview else { return event }
            let loc = event.locationInWindow
            // 内容区永远不插手（链接、选区、滚动都归原生）
            guard loc.y >= window.contentLayoutRect.maxY else { return event }
            guard let hit = theme.hitTest(loc) else { return event }

            var interactive = false
            var view: NSView? = hit
            while let current = view {
                let name = String(describing: type(of: current))
                // 红绿灯是 NSButton 子类；toolbar item 挂在 NSToolbarItemViewer 下
                // （链上既无 button/control 字样、也不是 NSControl，只能按容器认）。
                // 标题文字是 NSTextField（不是 NSButton），不算交互，仍要能拖。
                if current is NSButton
                    || name.localizedCaseInsensitiveContains("button")
                    || name.localizedCaseInsensitiveContains("control")
                    || name.contains("ToolbarItemViewer") {
                    interactive = true
                    break
                }
                view = current.superview
            }
            if !interactive {
                window.performDrag(with: event)
                return nil
            }
            return event
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        // 系统（Finder 双击）打开的文件优先，启动时不再自动恢复上次文档
        DocState.shared.didOpenViaSystem = true
        DocState.shared.open(u)

        // 单窗口应用：Finder 打开只替换当前文档，并复用现有主窗口尺寸。
        application.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let window = application.windows.first(where: {
                $0.frameAutosaveName == MainWindow.autosaveName
            }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    @objc private func languageDidChange(_ notification: Notification) {
        updateMainMenu()
        scheduleMainMenuUpdates()
    }

    @objc private func systemLocaleDidChange(_ notification: Notification) {
        DocState.shared.refreshSystemLanguage()
        scheduleMainMenuUpdates()
    }

    @objc private func menuStructureDidChange(_ notification: Notification) {
        guard let changed = notification.object as? NSMenu else { return }
        // 内容层菜单（工具栏菜单、右键菜单）随每次视图重绘被重建，它们与主菜单无关，
        // 不该触发主菜单改写——否则任何界面操作都会白跑一遍主菜单。
        let belongs = belongsToMainMenu(changed)
        guard belongs else { return }
        scheduleMenuUpdate()
    }

    /// 一批通知只改写一次：异步合并，下一轮 run loop 兜底执行。
    private func scheduleMenuUpdate() {
        guard !pendingMenuUpdate else { return }
        pendingMenuUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMenuUpdate = false
            self.updateMainMenu()
        }
    }

    /// 判断被改动的菜单是否属于主菜单层级（主菜单自身或其子菜单）。
    private func belongsToMainMenu(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let candidate = current {
            if candidate === NSApp.mainMenu { return true }
            current = candidate.supermenu
        }
        return false
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        DocState.shared.refreshSystemLanguage()
        updateMainMenu()
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {}

    @objc private func menuDidEndTracking(_ notification: Notification) {}

    private func scheduleMainMenuUpdates() {
        for delay in [0.0, 0.05, 0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.updateMainMenu()
            }
        }
    }

    private func updateMainMenu() {
        guard !isLocalizingMainMenu, let menu = NSApp.mainMenu else { return }
        isLocalizingMainMenu = true
        defer { isLocalizingMainMenu = false }
        MainMenuLocalizer.update(menu, language: DocState.shared.resolvedLanguage)
    }


}
