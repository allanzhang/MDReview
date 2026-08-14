# HANDOFF.md — MDReview 项目交接文档

> 用途：供接手的新模型/协作者在不依赖对话历史的前提下，快速恢复上下文并继续任务。
> 最后更新：2026-08-14（macOS, Swift 6, Xcode 工程，已上传 GitHub）

---

## 1. 项目定位

**MDReview** —— macOS 轻量级 Markdown 阅读器（用户的个人工具，目标替代 Typora）。
- 只做「干净阅读 + 基础审阅工具」，**不做编辑、不做主题商城、不做云同步、不做导出、不做插件**（避免 Typora 式臃肿，这是用户明确的产品边界）。
- 当前阶段（P0）**不含本地文件夹目录树挂载**功能——用户决定暂缓，P1 多项功能因此延后。

## 2. 技术栈

| 层 | 选型 |
|---|---|
| 语言/框架 | Swift 6（严格并发）、SwiftUI、macOS 14+ |
| 渲染内核 | `WKWebView` + 本地内联 HTML（**完全离线，零网络**） |
| Markdown 解析 | `markdown-it` 14.1.0（CommonMark + GFM 表格/删除线/任务列表） |
| 数学公式 | `KaTeX` 0.16.11（含 auto-render + woff2 字体，全内置） |
| 代码高亮 | `highlight.js` 11.10.0（common 语言包，36 语言）+ github / github-dark 双主题 |
| 脚注 | `markdown-it-footnote` 4.0.0 |
| 工程生成 | `xcodegen`（`project.yml` → `MDReview.xcodeproj`），ad-hoc 签名 |

## 3. 当前完成度（P0，除文件夹目录树外已全部落地）

| 功能 | 实现要点 | 状态 |
|---|---|---|
| 代码高亮 | 内置 highlight.js + 双主题；渲染后对 `#content pre code` 调 `hljs.highlightElement` | ✅ 编译+逻辑验证 |
| 脚注 | `md.use(footnote)` 注册；reader.css 补 `.footnotes` 样式 | ✅ |
| GFM 换行 | `markdownit({breaks:true})` | ✅ |
| 系统暗色 | `color-scheme: light dark` + `@media (prefers-color-scheme: dark)`；hljs 暗色主题包在媒体查询内随系统切换 | ✅ 编译含资源 |
| 大纲双向同步 | 新增 `active` 消息通道；页面滚动（rAF 节流）回传当前章节 id，`OutlineView` 反向高亮 | ✅ 编译通过 |
| 渲染/源码切换 | `DocState.showSource` + `SourceView`（等宽、可选中），覆盖在 WebView 上不卸载渲染状态 | ✅ 编译通过 |
| 外部编辑器 | 工具栏按钮 + `Cmd+E`，优先 Cursor/VSCode，未装退回默认 app | ✅ 编译通过 |
| 最近文件持久化 | `UserDefaults`（key `mdreview.recent`）跨启动保存，启动过滤失效路径，上限 30 | ✅ 编译通过 |
| 渲染架构稳定性 | 单次导航内联 markdown + `WKScriptMessageHandler` 回传大纲 + `pageLoaded` 闸门 | ✅ |

### 已修复的历史 Bug
- **「无大纲 + 持续报错」**：根因是 `renderCurrent()` 在 `loadHTMLString` 后立刻 `evaluateJavaScript`（页面未就绪）→ "Request to run JavaScript failed"；以及旧版大纲靠脆弱时序取回。改为单次导航内联 + 消息回传 + 闸门。
- **`Publishing changes from within view updates` 断言**：`.onChange(of: doc.url)` / `.onAppear` 在视图更新周期内同步写 `@Published`。改为 `DispatchQueue.main.async` 延后。
- **CFBundleIdentifier 冲突**：Info.plist（`com.doubleeagle.MDRview`）、project.yml（`com.doubleeagle.mdreview`）、构建设置（`com.doubleeagle.MDReview`）三重不一致。统一为 Info.plist 用 `$(PRODUCT_BUNDLE_IDENTIFIER)` 变量。

## 4. Backlog（未做，按优先级）

### P0-1（用户暂缓，但其余 P0 已绕过它完成）
- **本地文件夹目录树挂载** + 启动恢复目录状态。**当前 recent 文件列表已独立持久化，不依赖目录树。**

### P1（全部依赖目录树，待目录树补上后做）
- 批量跨文件搜索
- 文件热更新（外部编辑后自动刷新）
- 超大文件分块懒加载

### P2 / P3
- 按需求文档定义，尚未细化。

### GUI 效果待实机确认（沙箱无 GUI，无法自测）
以下需用户在 Xcode `Cmd+R` 实机验证：
1. 系统切暗色时正文/代码块是否跟随变暗；
2. 滚动长文档时左侧大纲是否反向高亮当前章节；
3. 「源码」按钮切换是否正常、`Cmd+E` 能否拉起 Cursor/VSCode；
4. 重启 App 后「最近文件」是否仍在。

## 5. 关键文件索引

| 文件 | 职责 |
|---|---|
| `MDReview/Sources/MarkdownRenderer.swift` | 渲染管线核心：`htmlTemplate` 内联依赖；`jsRenderInline` 注册 footnote/breaks/高亮；`jsFunctions` 滚动/搜索/active 监听；`Coordinator` 处理 `outline`/`active` 消息；`pageLoaded` 闸门 |
| `MDReview/Sources/ContentView.swift` | UI：`NavigationSplitView`、侧边栏 Segmented Picker（大纲/最近）、工具栏（折叠/打开/搜索/源码/外部编辑器）、`SourceView`、`openInExternalEditor` |
| `MDReview/Sources/DocState.swift` | 状态 + 持久化：`rawText`/`url`/`recent`(UserDefaults)/`showSource`/`showOutline`/`columnVisibility`/`open()` |
| `MDReview/Sources/OutlineView.swift` | 大纲列表 + 反向高亮（`activeID` 选中态） |
| `MDReview/Sources/ReaderWebView.swift` | WebView 封装 + 拖拽打开文件 |
| `MDReview/Sources/RecentView.swift` | 最近文件列表 |
| `MDReview/Sources/MDReviewApp.swift` | App 入口（`.onOpenURL` 打开 md 文件） |
| `MDReview/Sources/Resources/reader.css` | 阅读样式 + 暗色 + 脚注 + 代码块 + 搜索高亮 |
| `MDReview/Sources/Resources/*.js` / `*.css` / `katex/fonts/*.woff2` | 内置渲染依赖（markdown-it / katex / highlight.js / footnote） |
| `MDReview/project.yml` | 工程定义：`bundleIdPrefix: com.doubleeagle`；`PRODUCT_BUNDLE_IDENTIFIER` 自动生成 `com.doubleeagle.MDReview`；ad-hoc 签名 |
| `MDReview/Sources/Info.plist` | `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`（**勿写死字面量**） |
| `.gitignore` | 排除 `MDReview.app/`、`DerivedData/`、`.workbuddy/`、`*.xcuserstate`、`.DS_Store` |

## 6. 构建与运行

```bash
cd MDReview
xcodegen generate                              # 由 project.yml 生成 MDReview.xcodeproj
xcodebuild -project MDReview.xcodeproj -scheme MDReview -configuration Debug \
  CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=YES
# 或直接 Xcode 打开 MDReview.xcodeproj 按 Cmd+R
```

- 首次 `xcodegen generate` 需要已 `brew install xcodegen`。
- 产物：`~/Library/Developer/Xcode/DerivedData/MDReview-*/Build/Products/Debug/MDReview.app`
- 编译仅有 2–3 条 benign 警告（`javaScriptEnabled` 弃用、`WKScriptMessage.name/body` 主线程隔离提示），不影响运行。

## 7. Git / GitHub

- 仓库：**`https://github.com/allanzhang/MDReview`**（public）
- 分支：`main`（本地跟踪 `origin/main`）
- 提交作者（首次提交）：`allanzhang <allanzhang@users.noreply.github.com>`（GitHub 隐私邮箱）。**用户可能想改为真实署名**，如有需要：`git commit --amend --author="姓名 <邮箱>"` 后强推。
- 远程已配置；日常 `git add -A && git commit && git push` 即可。
- **重建仓库注意**：GitHub API 偶发 502，重试即可；设置可见性务必用 `gh api repos/... -X PATCH -F private=false`（`-F` 传真实布尔，勿用 `-f` 否则被当字符串 truthy 建成 private）。

## 8. 关键约定与易踩的坑

1. **绝不在视图更新周期内同步写 `@Published`**：`.onChange` / `.onAppear` 里的副作用一律 `DispatchQueue.main.async` 延后，否则触发 SwiftUI 断言。
2. **CFBundleIdentifier 必须用变量**：`$(PRODUCT_BUNDLE_IDENTIFIER)`，勿在 Info.plist 或 project.yml 写死字面量，否则大小写不一致导致构建失败。
3. **依赖全内置离线**：新增渲染能力时，把 JS/CSS/字体下载进 `Sources/Resources/` 并内联，不要引外部 CDN。
4. **渲染架构**：markdown 内联进 HTML 一次性 `loadHTMLString`；大纲/active 经 `WKScriptMessageHandler.postMessage` 回传 Swift；`pageLoaded` 闸门防止页面未就绪时 `evaluateJavaScript`。
5. **高德/架构图等可视化需求**不在本项目范围（纯 macOS 原生 App）。

## 9. 需求文档（用户原始清单，只读参考）

`/Users/allan/Downloads/Mac 轻量 AI 专属 Markdown 阅读器 · 最终版功能需求清单.md`
定义了 P0–P3 及「永久不做」项，是功能取舍的权威依据。

---

**接手建议**：先 `git pull` 最新 `main`，`xcodegen generate` + `xcodebuild` 跑通，再用 Xcode `Cmd+R` 实机验证第 4 节列出的 GUI 待确认项；之后从 Backlog（第 4 节）挑优先级继续。
