# Implementation Tasks

## Gate Summary

**本 change 为实现完成后的规格追认，非规格先行。**

- L1 OpenSpec 与 L2 spec-lint 未在实现前执行，构成对全局门禁 §7 的偏离，此处如实标注，不作为流程合规证明。
- 本 change 的 spec 依据**已落地的代码**撰写，`openspec validate --strict` 与 `spec-lint` 必须在归档前通过。
- 人工视觉验收（全局门禁 §8）是本 change 唯一的验收标准；机械自检结果不构成验收，agent 不得给出视觉结论。
- 人工验收栏未回填前，本 change 不得标记为完成、不得 archive。
- 历史 change（`add-auto-update`、`add-localization-and-about-github`）不在本次范围，不 archive、不同步其 specs。

## 1. 行号索引（L3 机械部分）

- [x] 1.1 新建 `Sources/SourceLineIndex.swift`，行首下标数组 + 二分查询，纯 Foundation 不依赖 AppKit。
- [x] 1.2 覆盖空文本、单行、文末换行、连续换行、CRLF、多字节字符、负下标与越界夹取、5 万行大文档。
- [x] 1.3 接入 `Tests/run.js`（`runSourceLineIndexTests`）。

## 2. 行号栏（L3 机械部分）

- [x] 2.1 新增 `LineNumberGutterView` 作为 `ThemedTextView` 子视图，`hitTest` 返回 `nil` 保证点击仍选中文本。
- [x] 2.2 新增 `SourceLineLayout` 承担容器坐标到文本视图坐标的换算，查询矩形固定横向覆盖正文（`x = 0`，`width = container.size.width`）。
- [x] 2.3 实现续行留空：仅当片段首字符等于行首下标时绘制行号。
- [x] 2.4 行号栏宽度随行数位数自适应，`textContainerInset` 同步让位。
- [x] 2.5 `syncGutterFrame` 在文本写入后与 frame 变化两处调用，避免 0 尺寸导致空 `dirtyRect`。

## 3. 当前行高亮（L3 机械部分）

- [x] 3.1 `ThemedTextView.draw` 在 `super.draw` 之后绘制高亮矩形，亮暗分别 5.5% / 22% 黑。
- [x] 3.2 高亮范围取选区扩行后的 `boundingRect(forGlyphRange:)`，跨软换行覆盖全部片段。
- [x] 3.3 `SourceTextCoordinator` 实现 `NSTextViewDelegate` 的 `textViewDidChangeSelection` 触发更新。
- [x] 3.4 行号栏当前行行号转强调色。
- [x] 3.5 失效范围取新旧高亮矩形并集，不做整屏重绘。

## 4. 机械自检（不构成验收）

- [x] 4.1 `xcodebuild -project MDReview.xcodeproj -scheme MDReview -configuration Debug -derivedDataPath /tmp/MDReviewDerivedData build` 成功。
- [x] 4.2 `node Tests/run.js` 全绿（含新增 26 条行索引断言）。
- [x] 4.3 新增 5 条源码契约断言，防止行号栏、续行留空、`hitTest`、选区回调、高亮绘制被无声移除。
- [ ] 4.4 `openspec validate --strict add-source-line-numbers` 通过。
- [ ] 4.5 `spec-lint` 通过（L2 语义门禁）。

## 5. 文档同步

- [x] 5.1 `README.md` 阅读导航项补入源码视图行号与当前行高亮。
- [x] 5.2 `Tests/TEST-CHECKLIST.md` 新增 9 条人工验收项。
- [x] 5.3 `Tests/interaction-inventory.md` 补入 6 条交互路径与覆盖状态。

## 6. 人工视觉验收（全局门禁 §8，唯一验收标准）

以下由用户在本地打包的 App 上逐条回填。**未回填前，本 change 状态为「待人工验收」。**

| # | 验收项 | 预期 | 人工结论 |
|---|---|---|---|
| 6.1 | 打开源码视图 | 左侧出现行号栏，每行一个号，与正文逐行对齐 | 待验收 |
| 6.2 | 滚动源码视图 | 行号跟随内容滚动，不错位、不重绘闪烁 | 待验收 |
| 6.3 | 拖窄窗口 | 换行位置变化后行号重排，仍与正文对齐 | 待验收 |
| 6.4 | 长行软换行 | 行号只在首行标号，续行留空 | 待验收 |
| 6.5 | 点选 / 拖选多行 | 覆盖的整行高亮，跨软换行时高亮整段，行号栏首行号转强调色 | 待验收 |
| 6.6 | 点击行号栏 | 不影响文本选区，仍可选中文字 | 待验收 |
| 6.7 | 打开含超长行的文档 | 行号连续递增不错号，滚动流畅 | 待验收 |
| 6.8 | 切到暗色外观 | 行号与当前行高亮配色跟随 | 待验收 |
| 6.9 | 源码 ↔ 渲染往返 | 行号与高亮仍在，滚动位置记忆不变 | 待验收 |
