import AppKit

@MainActor
enum MainMenuLocalizer {
    private static let keys = [
        "About MDReview",
        "Check for Updates…",
        "Open…",
        "Clear Menu",
        "Open Recent",
        "Open in External Editor…",
        "Export as HTML…",
        "Export as PDF…",
        "Export",
        "Find",
        "Toggle Sidebar",
        "Toggle Source / Rendered",
        "Follow System",
        "Light",
        "Dark",
        "Appearance",
        "Language",
        "Copy",
        "Paste",
        "Select All"
    ]

    private static let standardItems: [(english: String, chinese: String)] = [
        ("Services", "服务"),
        ("Hide MDReview", "隐藏 MDReview"),
        ("Hide Others", "隐藏其他"),
        ("Show All", "全部显示"),
        ("Quit MDReview", "退出 MDReview"),
        ("File", "文件"),
        ("Close", "关闭"),
        ("Close All", "全部关闭"),
        ("Edit", "编辑"),
        ("Undo", "撤销"),
        ("Redo", "重做"),
        ("Cut", "剪切"),
        ("Delete", "删除"),
        ("AutoFill", "自动填充"),
        ("Contacts…", "联系人…"),
        ("Passwords…", "密码…"),
        ("Credit Cards…", "信用卡…"),
        ("Start Dictation…", "开始听写…"),
        ("Emoji & Symbols", "表情与符号"),
        ("View", "显示"),
        ("Enter Full Screen", "进入全屏幕"),
        ("Exit Full Screen", "退出全屏幕"),
        ("Show Toolbar", "显示工具栏"),
        ("Hide Toolbar", "隐藏工具栏"),
        ("Customize Toolbar…", "自定工具栏…"),
        ("Window", "窗口"),
        ("Minimize", "最小化"),
        ("Minimize All", "全部最小化"),
        ("Zoom", "缩放"),
        ("Zoom All", "全部缩放"),
        ("Fill", "填充"),
        ("Center", "居中"),
        ("Move & Resize", "移动与调整大小"),
        ("Tile Window to Left of Screen", "将窗口拼贴到屏幕左侧"),
        ("Tile Window to Right of Screen", "将窗口拼贴到屏幕右侧"),
        ("Full Screen Tile", "全屏幕平铺"),
        ("Remove Window from Set", "从组中移除窗口"),
        ("Bring All to Front", "前置全部窗口"),
        ("Arrange in Front", "排在前面"),
        ("Help", "帮助"),
        ("MDReview Help", "MDReview帮助")
    ]

    /// 系统菜单项的 action 与其显示语言无关：系统处于中英文之外的第三种语言，
    /// 或标题被 AppKit 重新本地化时，仍能靠 action 识别并改写。
    private static let selectorTitles: [String: (english: String, chinese: String)] = [
        "terminate:": ("Quit MDReview", "退出 MDReview"),
        "hide:": ("Hide MDReview", "隐藏 MDReview"),
        "hideOtherApplications:": ("Hide Others", "隐藏其他"),
        "unhideAllApplications:": ("Show All", "全部显示"),
        "close:": ("Close", "关闭"),
        "performClose:": ("Close", "关闭"),
        "closeAll:": ("Close All", "全部关闭"),
        "undo:": ("Undo", "撤销"),
        "redo:": ("Redo", "重做"),
        "cut:": ("Cut", "剪切"),
        "delete:": ("Delete", "删除"),
        "toggleFullScreen:": ("Enter Full Screen", "进入全屏幕"),
        "toggleToolbarShown:": ("Hide Toolbar", "隐藏工具栏"),
        "customizeToolbar:": ("Customize Toolbar…", "自定工具栏…"),
        "arrangeInFront:": ("Bring All to Front", "前置全部窗口"),
        "performMiniaturize:": ("Minimize", "最小化"),
        "performZoom:": ("Zoom", "缩放"),
        "showHelp:": ("MDReview Help", "MDReview帮助"),
        "startDictation:": ("Start Dictation…", "开始听写…"),
        "orderFrontCharacterPalette:": ("Emoji & Symbols", "表情与符号")
    ]

    static func update(
        _ menu: NSMenu,
        language: AppLanguage,
        string: (String, AppLanguage) -> String = { key, language in
            L10n.string(key, language: language)
        }
    ) {
        for item in menu.items {
            if item.isSeparatorItem { continue }

            if let key = matchingKey(for: displayTitle(of: item), string: string) {
                setTitle(string(key, language), on: item)
            } else if let standard = matchingStandardItem(for: item) {
                setTitle(standardTitle(standard, on: item, language: language), on: item)
            }

            // 帮助菜单的搜索框是 NSSearchField 视图，placeholder 独立于标题，需单独改写。
            if let searchField = searchField(in: item) {
                searchField.placeholderString = string("Search", language)
                searchField.needsDisplay = true
            }

            if let submenu = item.submenu {
                update(submenu, language: language, string: string)
            }
        }
    }

    private static func searchField(in item: NSMenuItem) -> NSSearchField? {
        guard let view = item.view else { return nil }
        if let field = view as? NSSearchField { return field }
        return firstSearchField(in: view)
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        for subview in view.subviews {
            if let field = subview as? NSSearchField { return field }
            if let found = firstSearchField(in: subview) { return found }
        }
        return nil
    }

    private static func setTitle(_ title: String, on item: NSMenuItem) {
        item.title = title
        if let attributedTitle = item.attributedTitle, attributedTitle.length > 0 {
            let updatedTitle = NSMutableAttributedString(attributedString: attributedTitle)
            updatedTitle.replaceCharacters(
                in: NSRange(location: 0, length: updatedTitle.length),
                with: title
            )
            item.attributedTitle = updatedTitle
        }
        // 顶层菜单栏项由 submenu.title 渲染，必须与 item.title 同步改写。
        if let submenu = item.submenu {
            submenu.title = title
        }
    }

    private static func displayTitle(of item: NSMenuItem) -> String {
        item.title.isEmpty ? (item.submenu?.title ?? "") : item.title
    }

    private static func matchingKey(
        for title: String,
        string: (String, AppLanguage) -> String
    ) -> String? {
        let candidate = normalized(title)
        return keys.first { key in
            candidate == normalized(string(key, .english)) ||
            candidate == normalized(string(key, .chinese))
        }
    }

    private static func matchingStandardItem(
        for item: NSMenuItem
    ) -> (english: String, chinese: String)? {
        if let action = item.action.map(NSStringFromSelector),
           let mapped = selectorTitles[action] {
            return mapped
        }
        let candidate = normalized(displayTitle(of: item))
        return standardItems.first { item in
            candidate == normalized(item.english) || candidate == normalized(item.chinese)
        }
    }

    /// 全屏与工具栏两项的文案随窗口状态变化。这里按菜单项当前文案判断状态，
    /// 不读取 NSApp（命令行测试环境没有运行中的 NSApplication）。
    private static func standardTitle(
        _ standard: (english: String, chinese: String),
        on item: NSMenuItem,
        language: AppLanguage
    ) -> String {
        let current = normalized(displayTitle(of: item))
        if current == normalized("Exit Full Screen") || current == normalized("退出全屏幕") {
            return language == .chinese ? "退出全屏幕" : "Exit Full Screen"
        }
        if current == normalized("Hide Toolbar") || current == normalized("隐藏工具栏") {
            return language == .chinese ? "隐藏工具栏" : "Hide Toolbar"
        }
        return language == .chinese ? standard.chinese : standard.english
    }

    private static func normalized(_ title: String) -> String {
        title
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .lowercased()
    }
}
