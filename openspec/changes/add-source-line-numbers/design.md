## Context

MDReview 源码视图是 `NSScrollView` + 只读 `NSTextView` 的 `NSViewRepresentable` 包装（`ContentView.swift`）。渲染态代码块已有行号栏：`MarkdownRenderer.swift` 的 `__polishCodeBlocks` 生成 `.code-gutter` 元素，`reader.css` 负责样式。

源码视图的实现必须同时满足两件事：

1. 行号要按逻辑行编号，而 `NSTextView` 默认软换行长行，一个逻辑行占多个视觉行。
2. 当前行高亮要垫在文字下面，而 `NSTextView` 自身在 `draw(_:)` 里填背景色。

## Goals / Non-Goals

**Goals:**

- 行号与当前行高亮在源码视图常开，无需切换，不引入偏好项。
- 行号编号与渲染态代码块行号栏视觉一致。
- 滚动时零重绘；绘制成本只与可视区行数相关。
- 行索引逻辑可独立单测，不依赖 AppKit。

**Non-Goals:**

- 不提供行号开关、行号栏隐藏、偏好持久化。
- 不实现点击行号选中整行、行号栏拖拽、当前行边框、独立插入光标竖条。
- 不改渲染端 JS / CSS、不改 `DocState`、不参与 HTML / PDF 导出（导出走渲染态，源码视图不导出）。
- 不新增本地化文案（无用户可见按钮或菜单项）。

## Decisions

### D1 行号栏作为文本视图子视图，而非 NSRulerView

AppKit 传统做法是 `NSRulerView`，但它的坐标系与文本翻转、`textContainerInset` 换算容易踩坑，且需额外占用滚动条列宽。选用作 `ThemedTextView` 的子视图：位置 `(0, 0)`，与文本同一坐标系，天然随内容滚动而滚动，滚动时零重绘。

**代价**：`hitTest` 返回 `nil` 让位给文本视图（保证点击仍能选中文本），并需要显式管理尺寸——`ThemedTextView()` 无参构造时宽高为 0，autoresizing 不能可靠跟随。

### D2 行片段遍历是行号栏与高亮的唯一换算源

新增 `SourceLineLayout`，把 `NSLayoutManager` 的行片段翻译成「逻辑行号 + 文本视图坐标矩形」。行号栏和当前行高亮共用它，保证两者纵向永远对齐。

坐标换算依据（已实测）：`NSLayoutManager` 返回的片段矩形是容器坐标，`NSTextView` 按 `textContainerInset` 摆放文本容器，两者相加即文本视图坐标。此 SDK 上 `NSTextContainer.origin` 已不可用，因此显式用 `textContainerInset` 换算。

**查询矩形陷阱**：`glyphRange(forBoundingRect:)` 收到的矩形必须横向覆盖正文。行号栏自身的 x 范围换算到容器坐标后落在正文左侧，直接用它查询会得到空区间，表现为"完全不显示行号"。因此查询矩形固定 `x = 0`、`width = container.size.width`，纵向按可视区收窄。

### D3 续行留空用首字符比对实现

片段的 `characterIndexForGlyph` 换算到逻辑行后，只有当片段起始字符等于该行行首下标时才是首片段，否则是软换行续行。续行不绘制行号。该判定写进 `SourceLineLayout.Fragment.isFirstOfLine`，行号栏只画 `isFirstOfLine` 的片段。

### D4 当前行高亮画在 `super.draw` 之后

`NSTextView` 自身在 `draw(_:)` 里填背景色，画在 `super` 之前会被覆盖。因此 `ThemedTextView.draw` 先调 `super.draw`，再在选区行范围内叠一层极淡墨色（亮色 5.5% 黑、暗色 22% 黑）。视觉上与垫在文字下方等价，且不需要动 `backgroundColor` 管线。

高亮矩形直接来自选区扩行后的 `boundingRect(forGlyphRange:)`，一个包围盒覆盖全部选中行（行之间无空隙），不必逐行拼接。失效范围取新旧高亮矩形的并集，不做整屏重绘。

### D5 选区跟踪走 NSTextViewDelegate

`SourceTextCoordinator` 实现 `NSTextViewDelegate`，以 `textViewDidChangeSelection(_:)` 触发高亮更新。点选、拖选、搜索跳转的 `setSelectedRange` 都会回调，无需逐路径埋点。

### D6 行号索引独立成文件

`SourceLineIndex` 放 `Sources/SourceLineIndex.swift`，纯 Foundation，不 import AppKit。原因是 `Tests/run.js` 用 `swiftc` 单独编译被测文件，`ContentView.swift` 依赖 SwiftUI 无法单独编译。

## Risks / Trade-offs

- **高亮为叠加而非垫底**：暗色下文字被 22% 黑墨色略微加深。视觉差异不可辨，换来的是不改动背景色管线。如验收发现差异明显，回退方案是清空 `tv.backgroundColor`、只留滚动视图背景，改回前置绘制。
- **行号栏尺寸依赖显式同步**：`applyGutterMetrics` 与 `handleFrameChange` 两处调用 `syncGutterFrame`，外加 autoresizing 兜底。若任一处遗漏，表现为行号不出现或高度不足。
- **`NSTextViewDelegate` 主 actor 隔离**：已按当前 SDK 命名 `textViewDidChangeSelection`，早期文档常见名为 `textDidChangeSelection` 的方法不会被调用。

## Migration Plan

无数据迁移。`DocState`、文档打开、滚动记忆、搜索索引均不受影响。

## Open Questions

无。
