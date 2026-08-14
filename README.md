# MDReview — 轻量 Markdown 审阅器

SwiftUI + WKWebView 原生 macOS 应用。定位：**AI 生成 `.md` 的只读审阅器**——快、简洁、克制，不堆编辑功能，对标 Typora 的"轻量纯净版"。

## 运行方式
- 打开 `MDReview.xcodeproj` → Xcode 里 `Cmd+R` 即可运行（已 ad-hoc 签名，本机直接跑）。
- 工程由 `project.yml` + `xcodegen` 生成（`brew install xcodegen` 后 `xcodegen generate`）。
- 想常驻：`xcodebuild -configuration Release` 构建一份，拖进「应用程序」文件夹。

## 打开文件
- 工具栏「打开」按钮（`NSOpenPanel`，快捷键 `Cmd+O`）
- 直接把 `.md` 拖进窗口（拖拽悬停有高亮反馈）
- Finder 右键 `.md` → 打开方式 → MDReview（已配置 `.md` / `.markdown` 文档关联）
- 最近文件列表（`UserDefaults` 持久化，启动时过滤失效路径）

## 功能

### 渲染（MD 语法全家桶，全部离线内置）
- **GFM**：表格 / 任务列表 / 删除线 / 单换行即换行（`breaks`，符合国内文档习惯）
- **KaTeX 数学公式**：`$...$` / `$$...$$`
- **Mermaid 图表**：按需加载（文档含 ` ```mermaid ` 才内联渲染库），失败降级保留原代码
- **代码高亮**：`highlight.js` 36 语言，亮/暗双主题；大文档分帧渐进高亮不阻塞首屏
- **扩展语法**：emoji、`==高亮==`、上下标、定义列表、脚注（footnote）
- **标题锚点**：悬停显示 `#` 链接，支持 `#` 片段跳转
- **图片**：相对路径按 `.md` 所在目录解析，`loading="lazy"` + `decoding="async"` 懒加载

### 导航
- **大纲双向同步**：侧栏 Outline 点选跳转；滚动时反向高亮当前章节
- **超大文档分块懒渲染**：>25 万字符自动按标题切分，初始渲染 6 段、滚动渐进加载——大文件秒开、滑动流畅（大纲跳转/进度恢复会自动先渲染目标段）

### 阅读工具
- **全文搜索**：`Cmd+F` 呼出 Spotlight 式悬浮面板（NSVisualEffectView 高斯模糊，融入工具栏按钮区域），输入 250ms 防抖、上/下跳转、命中计数
- **渲染 / 源码对照**：More 菜单切换（只读、等宽、可选中）
- **外部编辑器**：`Cmd+E`，优先 Cursor / VSCode，未装退回系统默认关联应用
- **阅读进度记忆**：按章节 id 存 localStorage（key 含文件名防串档），重开自动回到上次位置
- **文件热更新**：监听当前文件，外部编辑器保存后 400ms 防抖自动重载；文件删除自动停止监听

### 外观
- **三态外观**：默认跟随系统；工具栏太阳/月亮按钮单击临时切换亮/暗（accent 高亮显示状态），再点回跟随，重启始终回到跟随系统
- 内容区、代码块、Mermaid、全部 UI 组件随外观联动（AppKit 层 `NSApp.appearance` 强制同步，无闪烁回退）

### 备份导出
- **导出 HTML**：静态预渲染快照（KaTeX / 高亮 / Mermaid 成品内联），**无 JS 依赖**——macOS 预览（空格）、QuickLook、Chrome 打开所见即所得
- **导出 PDF**：WKWebView 原生分页，与屏幕渲染一致（分块模式先强制渲染全文）

### 界面
- 工具栏精简：Sidebar / Open / Search / 外观 / More / Export，语义分组克制
- 侧边栏：Outline / History 大按钮切换（图标+文字、选中高亮），列表首尾行圆角、hover 反馈
- 空状态引导页、窗口标题显示文件名+路径、拖拽高亮
- Light / Dark 组件层次感分别优化（light 实底+描边，dark 玻璃+边界）

## 工程结构
```
MDReview/                         (工程根目录)
├── MDReview.xcodeproj           (由 xcodegen 生成)
├── MDReview.app                 (编译产物，本机可直接运行)
├── project.yml                  (xcodegen 配置)
├── README.md
└── Sources/                     (源码文件夹)
    ├── MDReviewApp.swift        (窗口场景 + AppKit 层外观控制)
    ├── DocState.swift           (全局状态 + 文件热更新监听 + 异步读盘)
    ├── MarkdownRenderer.swift   (渲染内核：JS 注入 / 分块渲染 / 搜索 / 导出)
    ├── ContentView.swift        (主界面：工具栏 / 侧栏 / 搜索条 / 空状态)
    ├── OutlineView.swift        (大纲列表)
    ├── RecentView.swift         (最近文件列表)
    ├── SearchPanel.swift        (Spotlight 式浮动搜索面板)
    ├── ReaderWebView.swift
    ├── Info.plist
    └── Resources/               (markdown-it / KaTeX / highlight.js / mermaid 等，全部内置离线)
```

## 技术
- Swift 6 / SwiftUI；渲染内核 `WKWebView` + 本地 `markdown-it`（CommonMark + GFM + 脚注）+ `KaTeX` + `highlight.js` + `mermaid` + `md-plugins`
- 所有依赖 JS/CSS/字体**全部内置，完全离线，零网络**
- 关键机制：
  - **单次导航**：markdown 经 `jsonString` 转义（含 `</script>` 防护）内联进 HTML 一次性加载
  - **大纲回传**：页面脚本渲染后 `postMessage` 回推 Swift；滚动经独立消息通道回传当前章节
  - **分块渲染**：`scanAndSplit` 按标题切分（跳过代码围栏），大纲统一由扫描生成，滚动渐进加载
  - **`pageLoaded` 闸门**：页面未就绪时一律跳过 `evaluateJavaScript`，杜绝报错

## 已知限制 / 明确不做
- **目录树**：暂缓（依赖它的批量跨文件搜索、侧栏过滤一并延后）
- 明确不做：编辑、个性化排版、云同步、插件、主题商城、`.txt`/`.rst` 等非 Markdown 格式
- 无标题的超大文档无切分点，走全量渲染；分块模式下搜索仅覆盖已渲染部分（懒渲染固有行为）
