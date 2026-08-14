# MDReview — 轻量 Markdown 审阅器

SwiftUI + WKWebView 原生 macOS 应用（仅自用）。定位：**AI 生成 `.md` 的只读审阅器**，不堆编辑功能，对标 Typora 的"轻量纯净版"。

## 运行方式
- 打开 `MDReview.xcodeproj` → Xcode 里 `Cmd+R` 即可运行（已 ad-hoc 签名，本机直接跑）。
- 或直接双击工程目录里的 `MDReview.app`。
- 想常驻：把 `MDReview.app` 拖进「应用程序」文件夹，再在 Xcode 里切 `Release` 构建一份更干净的。

## 打开文件
- 工具栏「打开」按钮（`NSOpenPanel`）
- 直接把 `.md` 拖进窗口
- Finder 右键 `.md` → 打开方式 → MDReview（首次需手动选一次；已配置 `.md` / `.markdown` 文档关联）

## 功能（MVP）
- **干净阅读渲染**：标题 / 列表 / 表格 / 代码块 / 引用 / 图片（相对路径自动按 `.md` 所在目录解析）
- **数学公式**：`$...$` / `$$...$$` 走 KaTeX
- **GFM 完整支持**：表格 / 任务列表 / 删除线 / 脚注（footnote）/ **单换行即换行**（`breaks`，符合国内文档习惯）
- **代码高亮**：`highlight.js`（common 包，36 种语言）对代码块做语法着色，含亮 / 暗双主题
- **系统暗色模式**：跟随 macOS 明暗自动切换，无需手动设置
- **大纲导航（双向同步）**：
  - 点大纲 → 平滑滚动定位
  - 页面滚动 → 大纲自动反向高亮当前章节（互斥高亮背景）
- **全文搜索**：工具栏放大镜 → 输入即搜，上/下跳转，当前命中项高亮
- **渲染 / 源码一键切换**：工具栏「源码」按钮，只读对照原文（等宽字体、可选中）
- **外部编辑器**：工具栏按钮或 `Cmd+E`，优先 Cursor / VSCode 打开当前文件，未装则退回系统默认关联应用
- **最近文件（持久化）**：`UserDefaults` 跨启动保存，重启后最近文件仍在（启动时过滤已失效路径）
- **界面布局**：
  - 侧边栏顶部放「大纲 / 最近」二选一切换器（Segmented Picker，互斥高亮）
  - 折叠/展开侧边栏的按钮放在**右侧内容区工具栏**（与打开、搜索、源码、外部编辑器同列）

## 工程结构
`project.yml` + `xcodegen` 生成 `.xcodeproj`，源码放在独立的 `Sources/` 文件夹（避免根目录同名嵌套）：
```
MDReview/                         (工程根目录)
├── MDReview.xcodeproj           (由 xcodegen 生成)
├── MDReview.app                 (编译产物，本机可直接运行)
├── project.yml                  (xcodegen 配置)
├── README.md
└── Sources/                     (源码文件夹)
    ├── MDReviewApp.swift
    ├── DocState.swift
    ├── MarkdownRenderer.swift
    ├── ContentView.swift
    ├── OutlineView.swift
    ├── RecentView.swift
    ├── ReaderWebView.swift
    ├── Info.plist
    └── Resources/               (markdown-it / KaTeX / highlight.js / footnote 的 JS·CSS·字体，全部内置)
        ├── reader.css
        ├── markdown-it.min.js
        ├── markdown-it-footnote.min.js
        ├── highlight.min.js
        ├── github.min.css / github-dark.min.css
        ├── katex.min.css / katex.min.js / katex-auto-render.min.js
        └── katex/fonts/*.woff2
```

## 技术
- Swift 6 / SwiftUI；渲染内核 `WKWebView` + 本地 `markdown-it`（CommonMark + GFM 表格/删除线/任务列表/脚注）+ `KaTeX` + `highlight.js`
- 所有依赖（markdown-it、footnote、highlight.js、KaTeX 的 JS/CSS/字体、reader.css）**全部内置，完全离线，零网络**
- 工程由 `project.yml` + `xcodegen` 生成（`brew install xcodegen` 后 `xcodegen generate`）

### 渲染架构（稳定性关键）
- **单次导航**：markdown 直接内联进 HTML 一次性 `loadHTMLString`，避免"先加载空模板再 `evaluateJavaScript` 渲染"的脆弱两步时序。
- **大纲回传走 `WKScriptMessageHandler`**：页面脚本渲染完成后 `postMessage` 把大纲推回 Swift，比 `evaluateJavaScript` 取回更可靠（`didFinishNavigation` 另留一次兜底读取）。
- **双向同步**：页面滚动经第二条消息通道（`active`）回传当前可视章节 id，Swift 给大纲对应项加高亮背景。
- **`pageLoaded` 闸门**：`evaluateJavaScript` 仅用于用户主动触发的滚动/搜索，且页面未就绪时一律跳过，杜绝 "Request to run JavaScript failed" 报错。

## 已知限制 / 后续
- **文件夹目录树挂载**（P0 原计划项）：本期按需求明确**不做**，因此「批量搜索 / 热更新 / 超大文件分块懒加载」等依赖目录树的 P1 功能一并延后。
- 明确不做：编辑、主题商城、云同步、导出、插件（避免 Typora 式臃肿）
