import Foundation

@main
struct DocStateTests {
    @MainActor
    static func main() async {
        let defaults = UserDefaults.standard
        let recentKey = "mdreview.recent"
        let lastUrlKey = "mdreview.lastUrl"
        let savedRecent = defaults.array(forKey: recentKey)
        let savedLast = defaults.string(forKey: lastUrlKey)
        defer {
            defaults.set(savedRecent, forKey: recentKey)
            defaults.set(savedLast, forKey: lastUrlKey)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdreview-docstate-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await runRecentContracts(in: directory)
        await runOpenGuards(in: directory)
        await runFileMonitor(in: directory)
        finishChecks()
    }
}

@MainActor
private func runRecentContracts(in directory: URL) async {
    let a = directory.appendingPathComponent("a.md")
    let b = directory.appendingPathComponent("b.md")
    try? "# a".write(to: a, atomically: true, encoding: .utf8)
    try? "# b".write(to: b, atomically: true, encoding: .utf8)

    let state = DocState()
    state.open(a)
    await waitUntil { state.url == a }
    state.open(b)
    await waitUntil { state.url == b }

    check("打开顺序",
          state.recent.first == b && state.recent.contains(a) && state.lastDocumentURL == b,
          "后打开的文档应置顶且成为启动恢复目标，实际 recent=\(state.recent.map(\.lastPathComponent))")

    state.clearRecent()
    check("清空后列表与恢复目标都清除",
          state.recent.isEmpty && state.lastDocumentURL == nil,
          "clearRecent 未同时清除 lastUrl，重启会恢复刚清空的文档")
    check("清空不关闭当前文档",
          state.url == b,
          "clearRecent 不应改变当前已打开的文档")

    state.open(b)
    await waitUntil { state.recent == [b] }
    check("清空后重开唯一文档回到列表",
          state.recent == [b] && state.lastDocumentURL == b,
          "重新打开当前文档被去重守卫吞掉，recent 与 lastUrl 没有恢复")

    state.open(a)
    await waitUntil { state.recent.first == a }
    state.removeRecent(b)
    check("删除单项只移除该项",
          !state.recent.contains(b) && state.recent.contains(a),
          "removeRecent 误删了其他条目")

    state.removeRecent(a)
    check("删除最后一项同时清除启动恢复目标",
          state.recent.isEmpty && state.lastDocumentURL == nil,
          "列表已空但 lastUrl 还在，重启会打开刚删除的文档")
}

@MainActor
private func runOpenGuards(in directory: URL) async {
    let state = DocState()
    let before = state.url
    state.open(directory.appendingPathComponent("notes.txt"))
    try? await Task.sleep(for: .milliseconds(100))
    check("非 markdown 文件被忽略",
          state.url == before,
          "打开 .txt 不应改变当前文档，实际 url=\(state.url?.path ?? "nil")")

    // 先存一条不存在的路径再构造 DocState，验证加载时过滤掉失效路径。
    let gone = directory.appendingPathComponent("gone.md").path
    UserDefaults.standard.set([gone], forKey: "mdreview.recent")
    let reloaded = DocState()
    check("失效路径不进最近列表",
          !reloaded.recent.contains { $0.path == gone },
          "文件已不存在的路径仍出现在 recent 中")

    let doc = directory.appendingPathComponent("dup.md")
    try? "# d".write(to: doc, atomically: true, encoding: .utf8)
    reloaded.open(doc)
    await waitUntil { reloaded.url == doc }
    reloaded.open(doc)
    await waitUntil { reloaded.recent.filter { $0 == doc }.count == 1 }
    check("重复打开不产生重复条目",
          reloaded.recent.filter { $0 == doc }.count == 1 && reloaded.recent.first == doc,
          "同一文档在 recent 中出现了多次或没有置顶")

    // 连续打开两个文件，后一个应胜出，先发起的读盘结果不得覆盖。
    let first = directory.appendingPathComponent("race1.md")
    let second = directory.appendingPathComponent("race2.md")
    try? "# 1".write(to: first, atomically: true, encoding: .utf8)
    try? "# 2".write(to: second, atomically: true, encoding: .utf8)
    reloaded.open(first)
    reloaded.open(second)
    await waitUntil { reloaded.url == second }
    try? await Task.sleep(for: .milliseconds(150))
    check("快速连续打开时后者胜出",
          reloaded.url == second && reloaded.rawText.contains("# 2"),
          "先发起的读盘结果覆盖了后打开的文档，url=\(reloaded.url?.lastPathComponent ?? "nil")")

    // 超过上限时最旧一条被淘汰。
    let capped = DocState()
    for i in 0..<31 {
        let f = directory.appendingPathComponent("cap\(i).md")
        try? "# \(i)".write(to: f, atomically: true, encoding: .utf8)
        capped.open(f)
    }
    let oldest = directory.appendingPathComponent("cap0.md")
    check("超过 30 篇淘汰最旧",
          capped.recent.count <= 30 && !capped.recent.contains(oldest),
          "recent 数量=\(capped.recent.count)，最旧条目仍在列表中")
}

@MainActor
private func runFileMonitor(in directory: URL) async {
    let file = directory.appendingPathComponent("watched.md")
    try? "initial".write(to: file, atomically: true, encoding: .utf8)
    let state = DocState()
    state.open(file)
    await waitUntil { state.url == file }

    try? "changed".write(to: file, atomically: true, encoding: .utf8)
    await waitUntil { state.hasPendingFileUpdate }
    check("外部保存标记待更新",
          state.hasPendingFileUpdate,
          "文件被外部改写后 hasPendingFileUpdate 没有置真")

    state.clearPendingFileUpdate()
    try? "changed again".write(to: file, atomically: true, encoding: .utf8)
    await waitUntil { state.hasPendingFileUpdate }
    check("原子替换保存后监听仍有效",
          state.hasPendingFileUpdate,
          "第一次外部保存后文件监听失效，后续改动不再标记")

    state.clearPendingFileUpdate()
    try? FileManager.default.removeItem(at: file)
    try? "resurrect".write(to: file, atomically: true, encoding: .utf8)
    try? await Task.sleep(for: .milliseconds(200))
    check("文件删除后不再持续标记更新",
          !state.hasPendingFileUpdate,
          "文件被删除后仍在标记待更新")
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return }
        try? await Task.sleep(for: .milliseconds(50))
    }
}
