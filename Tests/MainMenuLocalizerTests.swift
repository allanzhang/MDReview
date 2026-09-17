import AppKit

func expectEqual(_ actual: String, _ expected: String, _ message: String) {
    guard actual == expected else {
        fputs("not ok - \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct MainMenuLocalizerTests {
    @MainActor
    static func main() {
        let menu = NSMenu()
        menu.addItem(withTitle: "About MDReview", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Language", action: nil, keyEquivalent: "")
        let standardItems = ["文件", "服务", "隐藏 MDReview", "撤销", "全部最小化", "联系人…"]
        standardItems.forEach { menu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
        menu.items[2].attributedTitle = NSAttributedString(
            string: "文件",
            attributes: [.foregroundColor: NSColor.labelColor]
        )

        let viewMenu = NSMenu()
        viewMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        // SwiftUI 生成的顶层项可能只有 submenu.title，菜单栏按 submenu.title 渲染
        let windowMenu = NSMenu(title: "窗口")
        let windowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        // 系统处于中文/英文之外的语言时，标题匹配失效，只能靠 action 识别系统项
        let fullScreenItem = NSMenuItem(
            title: "Vollbild",
            action: NSSelectorFromString("toggleFullScreen:"),
            keyEquivalent: "f"
        )
        menu.addItem(fullScreenItem)

        // 帮助菜单里的搜索框是 NSSearchField 视图，placeholder 不随 item.title 变化
        let helpSearchField = NSSearchField()
        helpSearchField.placeholderString = "Search"
        let helpSearchItem = NSMenuItem()
        helpSearchItem.view = helpSearchField
        menu.addItem(helpSearchItem)

        MainMenuLocalizer.update(menu, language: .chinese) { key, language in
            let chinese = [
                "About MDReview": "关于 MDReview",
                "Language": "语言",
                "Find": "查找",
                "Search": "搜索",
                "View": "显示"
            ]
            if language == .chinese {
                return chinese[key] ?? key
            }
            return key
        }

        expectEqual(menu.items[0].title, "关于 MDReview", "app menu title")
        expectEqual(menu.items[1].title, "语言", "language menu title")
        expectEqual(menu.items[2].title, "文件", "standard File menu title")
        expectEqual(menu.items[3].title, "服务", "standard Services menu title")
        expectEqual(menu.items[4].title, "隐藏 MDReview", "standard Hide title")
        expectEqual(menu.items[5].title, "撤销", "standard Undo title")
        expectEqual(menu.items[6].title, "全部最小化", "standard Minimize All title")
        expectEqual(menu.items[7].title, "联系人…", "standard AutoFill contact title stays Chinese")
        expectEqual(menu.items[9].title, "窗口", "top-level item with submenu-only title")
        expectEqual(menu.items[9].submenu?.title ?? "", "窗口", "top-level submenu title")
        expectEqual(menu.items[10].title, "进入全屏幕", "action-identified full screen title")
        expectEqual(helpSearchField.placeholderString ?? "", "搜索", "help search placeholder in Chinese")
        expectEqual(viewMenu.items[0].title, "查找", "nested menu title")

        MainMenuLocalizer.update(menu, language: .english) { key, language in
            let chinese = [
                "About MDReview": "关于 MDReview",
                "Language": "语言",
                "Find": "查找"
            ]
            if language == .chinese {
                return chinese[key] ?? key
            }
            return key
        }
        expectEqual(menu.items[0].title, "About MDReview", "custom app menu back to English")
        expectEqual(menu.items[2].title, "File", "standard File menu back to English")
        expectEqual(
            menu.items[2].attributedTitle?.string ?? "",
            "File",
            "attributed standard File menu back to English"
        )
        expectEqual(menu.items[3].title, "Services", "standard Services menu back to English")
        expectEqual(menu.items[4].title, "Hide MDReview", "standard Hide back to English")
        expectEqual(menu.items[5].title, "Undo", "standard Undo back to English")
        expectEqual(menu.items[6].title, "Minimize All", "standard Minimize All back to English")
        expectEqual(menu.items[7].title, "Contacts…", "standard AutoFill contact back to English")
        expectEqual(menu.items[9].title, "Window", "top-level item with submenu-only title back to English")
        expectEqual(menu.items[9].submenu?.title ?? "", "Window", "top-level submenu title back to English")
        expectEqual(menu.items[10].title, "Enter Full Screen", "action-identified full screen back to English")
        expectEqual(helpSearchField.placeholderString ?? "", "Search", "help search placeholder back to English")
        expectEqual(viewMenu.items[0].title, "Find", "nested custom menu back to English")
        print("ok - main menu localizer tests")
    }
}
