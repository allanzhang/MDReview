# MDReview — 轻量 Markdown 审阅器

SwiftUI + WKWebView 原生 macOS 应用。定位：**AI 生成 `.md` 的只读审阅器**——快、简洁、克制，不堆编辑功能，对标 Typora 的"轻量纯净版"。

当前版本：**V1.2.1**（2026-08-24）

## 运行方式
- 打开 `MDReview.xcodeproj` → Xcode 里 `Cmd+R` 即可运行（已 ad-hoc 签名，本机直接跑）。
- 工程由 `project.yml` + `xcodegen` 生成（`brew install xcodegen` 后 `xcodegen generate`）。
- 想常驻：直接下载 [Releases](https://github.com/allanzhang/MDReview/releases) 附件里的 `MDReview-<版本>.zip`，解压拖进「应用程序」文件夹；或 `xcodebuild -configuration Release` 自己构建一份。

## 打开文件
- 工具栏「打开」或 **File > Open…**（`Cmd+O`，`NSOpenPanel`）
- 直接把 `.md` 拖进窗口（拖拽悬停有高亮反馈）
- Finder 右键 `.md` → 打开方式 → MDReview（已配置 `.md` / `.markdown` 文档关联）
- **File > Open Recent** 最近文档菜单 + 侧栏 Recent 列表（`UserDefaults` 持久化，启动时过滤失效路径；可右键移除 / 清空）
- **启动恢复**：自动重开上次文档，并记住窗口位置/大小、侧栏显隐

## 功能

### 渲染（MD 语法全家桶，全部离线内置）
- **GFM**：表格 / 任务列表 / 删除线 / 单换行即换行（`breaks`，符合国内文档习惯）
- **表格列宽内容测宽**：按每列 `max-content` 计算理想宽度，写入 `colgroup` + fixed 布局；窄容器下最小约 120px，避免首列被挤压或单列独占（含图片、合并单元格的表格自动回退原布局）
- **代码块**：语言栏 + 行号 + 右上角 Copy 按钮；长行自适应换行；MDReview 统一调色板高亮（蓝=关键字 / 绿=字符串 / 琥珀=数字 / 紫=函数，浅深同色相变体）
- **任务列表**：静态禁用 checkbox，前置圆点，与普通列表缩进一致
- **KaTeX 数学公式**：`$...$` / `$$...$$`（math 行内规则先拦截再渲染，防 markdown-it 破坏）
- **Mermaid 图表**：按需加载（文档含 ` ```mermaid ` 才内联渲染库），失败降级保留原代码
- **代码高亮**：`highlight.js` 36 语言；token 色按真实容器背景校验对比度（浅色 ≥ 4.5:1、深色 ≥ 5.2:1）；大文档分帧渐进高亮不阻塞首屏
- **扩展语法**：emoji、`==高亮==`、单波浪线按内容分下标/删除线（`H~2~O` / `~文字~`）、上标、定义列表、脚注
- **标题锚点**：保留标题 id 跳转能力，不再显示 `#` 链接，标题与正文绝对左对齐
- **图片**：相对路径按 `.md` 所在目录解析，`loading="lazy"` + `decoding="async"` 懒加载
- **字号跟随系统**：正文基准字号读系统 body 文本样式（放大系统字号，正文/标题/代码等比缩放）

### 导航
- **大纲双向同步**：侧栏 Outline 点选平滑跳转；正文滚动时反向高亮当前章节，大纲跟随滚动保持激活条目可视；点击后程序化滚动不会抢走选中
- **标题树层级**：H1~H4+ 以缩进 + 字号 + 字重 + 文字色四重区分，一眼可辨；有子标题的节点带 ▶/▼ 三角可折叠/展开子树；标题强制单行、超长截断为 …，hover tooltip 展示全文
- **超大文档分块懒渲染**：>25 万字符自动按标题切分，初始渲染 6 段、滚动渐进加载——大文件秒开、滑动流畅（大纲跳转/进度恢复会自动先渲染目标段）

### 阅读工具
- **全文搜索**：工具栏原生搜索框，点击搜索按钮展开；`Cmd+F` 聚焦并预填选中文字；输入 250ms 防抖、**Enter 下一个 / Shift+Enter 上一个**、计数显示在框内、清空按钮只清内容、失去焦点自动收起
- **渲染 / 源码对照**：工具栏纯图标按钮、View 菜单、阅读区右键均可切换；两个视图的滚动位置、阅读进度、大纲高亮独立记忆，Source 滚动位置按文档持久化，来回切换不会互相污染
- **外部编辑器**：`Cmd+E`，优先 Cursor / VSCode，未装退回系统默认关联应用
- **阅读进度记忆**：按章节 id 存 **Swift/UserDefaults**（非 localStorage），重开自动回到上次位置
- **文件热更新**：监听当前文件，外部编辑器保存后 400ms 防抖自动重载；文件删除自动停止监听
- **右键菜单**：正文（Copy / Reveal in Finder / 外部编辑器 / 导出 HTML/PDF）、Recent 行（显示位置 / 复制路径 / 外部编辑器 / 移除）、Outline 行（复制标题）

### 外观
- **三态外观**：默认跟随系统；工具栏月亮/太阳按钮单击临时切换亮/暗（图标表示"点击后切换的方向"），再点回跟随，重启始终回到跟随系统
- **dark 主题**：中性灰调色（页面 `#262626`、代码块 `#1d1d1d` 比页面沉一档、行内代码芯片 `#404040` 比页面亮一档），明亮通透不发脏
- **Codex 式实底界面**：侧栏 / 工具栏不透明实底（无磨砂玻璃），选中 / hover 为中性灰圆角底、文字保持原色不反白，UI chrome 零 accent 蓝
- 内容区、代码块、Mermaid、全部 UI 组件随外观联动（AppKit 层 `NSApp.appearance` 强制同步，无闪烁回退）

### 备份导出
- **导出 HTML**：静态预渲染快照（KaTeX / 高亮 / Mermaid 成品内联），**无 JS 依赖**——macOS 预览（空格）、QuickLook、Chrome 打开所见即所得
- **导出 PDF**：WKWebView 原生分页，与屏幕渲染一致（分块模式先强制渲染全文）
- 导出成功弹居中对齐确认面板，可一键 **Show in Finder**

### 界面
- **菜单栏**：File（Open…`⌘O` / Open Recent / External Editor…`⌘E` / Export）、View（Sidebar `⌃⌘S` / Source-Rendered / Appearance）；不提供 New Window / Tab
- **工具栏**：Sidebar / Open / Search `⌘F` / Source-Rendered / 外观 / Export，语义分组克制
- **侧栏**：Outline / Recent 中性灰轨道 + 实底滑块切换；Outline 隐藏滚动指示器；列表行圆角、hover / 选中反馈
- **阅读进度条**：内容区顶部渐变胶囊进度条，带轻微阴影和动画
- **空状态引导页**（大 Open 按钮）、窗口标题显示文件名 + 目录 + 字数、拖拽高亮
- **App 图标**：标准 Assets.xcassets（16~512 @1x/@2x 全尺寸集）

## 发布流程
1. 版本号三处同步：`CHANGELOG.md`（日期 + 条目）、`Sources/Info.plist`、`project.yml`（xcodegen 会回写 Info.plist，漏改会被打回旧版本）
2. commit → `git tag -a v<x.y.z>` → `git push origin main && git push origin v<x.y.z>`
3. `gh release create v<x.y.z>` 发布 notes（取自 CHANGELOG 对应段），并附应用包资产：Release 配置构建后 `ditto -c -k --keepParent MDReview.app MDReview-<x.y.z>.zip`，`gh release upload` 上传

## 工程结构
```
MDReview/                         (工程根目录)
├── MDReview.xcodeproj           (由 xcodegen 生成)
├── project.yml                  (xcodegen 配置，含 AppIcon 编译设置)
├── README.md
└── Sources/                     (源码文件夹)
    ├── MDReviewApp.swift        (App 入口 + 菜单命令 + AppKit 外观控制)
    ├── DocState.swift           (全局状态 + 文件热更新 + 最近/侧栏/上次文档记忆)
    ├── MarkdownRenderer.swift   (渲染内核：JS 注入 / 分块渲染 / 搜索 / 导出 / 进度回传)
    ├── ContentView.swift        (主界面：工具栏 / 侧栏 / 搜索条 / 空状态 / 进度条)
    ├── OutlineView.swift        (大纲列表)
    ├── RecentView.swift         (最近文件列表)
    ├── NativeSearchField.swift  (工具栏原生搜索框)
    ├── ReaderWebView.swift
    ├── Assets.xcassets          (App 图标)
    ├── Info.plist
    └── Resources/               (markdown-it / KaTeX / highlight.js / mermaid 等，全部内置离线)
```

## 技术
- Swift 6 / SwiftUI；渲染内核 `WKWebView` + 本地 `markdown-it`（CommonMark + GFM + 脚注）+ `KaTeX` + `highlight.js` + `mermaid` + `md-plugins`
- 所有依赖 JS/CSS/字体**全部内置，完全离线，零网络**
- 关键机制：
  - **单次导航**：markdown 经 `jsonString` 转义（含 `</script>` 防护）内联进 HTML 一次性加载
  - **消息通道**：页面脚本 `postMessage` 回推大纲 / 当前章节 / 阅读进度（0~1）到 Swift
  - **表格测宽**：克隆表格按 `max-content` 测列宽，再写 `colgroup` + fixed 布局；只测一次，滚动/切主题不重复计算
  - **视图状态隔离**：rendered 记录精确 `scrollY`，source 独立保存滚动偏移，切换时只恢复当前视图自己的状态
  - **分块渲染**：`scanAndSplit` 按标题切分（跳过代码围栏），大纲统一由扫描生成，滚动渐进加载
  - **`pageLoaded` 闸门**：页面未就绪时一律跳过 `evaluateJavaScript`，杜绝报错
  - **菜单动作总线**：File/View 菜单命令经 NotificationCenter 转发给主界面执行

## 已知限制 / 明确不做
- **目录树**：暂缓（依赖它的批量跨文件搜索、侧栏过滤一并延后）
- 明确不做：编辑、个性化排版、云同步、插件、主题商城、`.txt`/`.rst` 等非 Markdown 格式、多 Tab
- 无标题的超大文档无切分点，走全量渲染；分块模式下搜索仅覆盖已渲染部分（懒渲染固有行为）
