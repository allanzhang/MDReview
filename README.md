# MDReview — 轻量 Markdown 审阅器

面向 AI 生成 `.md` 文档的 macOS 只读审阅器。基于 Swift 6、SwiftUI 与 WKWebView，聚焦流畅阅读、内容导航和导出，不提供编辑功能。

当前版本：**v1.6.1**

## 核心能力

- **离线渲染**：CommonMark + GFM、表格、任务列表、脚注、定义列表、emoji、上下标和高亮；支持 KaTeX 数学公式与 Mermaid 图表。
- **代码阅读**：代码高亮、行号、一键复制、长行换行和代码块折叠。
- **阅读导航**：大纲双向同步、全文搜索、渲染 / 源码切换、阅读进度恢复、系统字号跟随与阅读区字号调节。
- **大文档支持**：超过 25 万字符的文档按标题分块懒渲染，优先保证首屏和滚动性能。
- **AI 审阅工作流**：外部编辑器保存后，在刷新按钮显示红点；点击刷新重新读盘，不自动打断当前阅读。支持 Copy as Quote 和本地 Markdown 内链跳转。
- **中英双语界面**：默认跟随系统语言（中文系统显示中文，其他语言显示英文），可在 View 菜单的 Language 里固定为「中文」或「English」，选择会保留到下次手动切换。
- **原生体验**：拖拽打开、最近文档、跟随系统 / 亮色 / 暗色外观、窗口状态恢复；About 页显示版本信息并提供 GitHub 项目入口。
- **导出**：导出无 JS 依赖的 HTML 静态快照，或导出与屏幕渲染一致的 PDF。
- **应用更新**：启动后自动检查 GitHub Release，也可从 About 或 App 菜单手动检查、下载并安装新版本。

渲染和日常使用完全离线；只有检查、下载应用更新时会访问 GitHub。

## 安装

要求：**macOS 14 或更高版本**。

1. 从 [Releases](https://github.com/allanzhang/MDReview/releases/latest) 下载 `MDReview-<版本>.zip`。
2. 解压后把 `MDReview.app` 拖进「应用程序」文件夹。

也可以克隆仓库后直接使用 Xcode 运行。

## 开发与验证

```bash
# 修改 project.yml 后重新生成工程
xcodegen generate

# 运行应用
open MDReview.xcodeproj

# 渲染器、更新与文件监听测试
node Tests/run.js

# 命令行编译验证
xcodebuild \
  -project MDReview.xcodeproj \
  -scheme MDReview \
  -configuration Debug \
  -derivedDataPath /tmp/MDReviewDerivedData \
  build
```

渲染器改动需要先在 `Tests/fixtures/renderer/` 添加最小复现；涉及 CommonMark 差异时，同步更新 `Tests/fixtures/commonmark/divergences.json` 和 `Docs/renderer-contract.md`。

## 本地打包

```bash
xcodebuild \
  -project MDReview.xcodeproj \
  -scheme MDReview \
  -configuration Release \
  -derivedDataPath /tmp/MDReviewRelease \
  build

ditto -c -k --keepParent \
  /tmp/MDReviewRelease/Build/Products/Release/MDReview.app \
  /tmp/MDReview-<版本>.zip
```

Release 附件必须命名为 `MDReview-<版本>.zip`，否则应用内更新无法识别。

## 发布流程

1. 同步版本号：`CHANGELOG.md`、`project.yml`、`Sources/Info.plist`。
2. 运行测试和 Release 构建，检查应用包版本、签名、架构与 ZIP 内容。
3. 提交并推送 `main`，创建并推送对应的 `vX.Y.Z` tag。
4. 创建 GitHub Release，上传 `MDReview-X.Y.Z.zip` 并附上对应 changelog。

```bash
gh release create vX.Y.Z MDReview-X.Y.Z.zip \
  --title "MDReview vX.Y.Z" \
  --notes-file /tmp/MDReview-X.Y.Z-notes.md
```

## 已知边界

- 不提供编辑、云同步、插件、多窗口或多 Tab；固定使用单一主窗口，也不支持 `.txt`、`.rst` 等非 Markdown 格式。
- 没有标题的超大文档无法分块，会走全量渲染。
- 分块模式下，全文搜索只覆盖已经渲染的章节。
