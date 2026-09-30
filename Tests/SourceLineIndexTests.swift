import Foundation

private var failures: [String] = []
private var passed = 0

private func check(_ name: String, _ condition: Bool, _ reason: String) {
    if condition {
        passed += 1
        print("ok - \(name)")
    } else {
        failures.append("\(name): \(reason)")
        print("FAIL - \(name): \(reason)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    check(name, actual == expected, "expected \(expected), got \(actual)")
}

/// 把整篇文本按行展开为 (行号, 首字符下标, 长度)，模拟行号栏要画出的序列。
private func laidOutLines(_ text: String) -> [(line: Int, start: Int, length: Int)] {
    let ns = text as NSString
    let index = SourceLineIndex(text)
    var result: [(Int, Int, Int)] = []
    for line in 0..<index.count {
        let start = index.start(ofLine: line)
        let end = line + 1 < index.count ? index.start(ofLine: line + 1) : ns.length
        result.append((line, start, max(0, end - start)))
    }
    return result
}

@main
struct SourceLineIndexTests {
    static func main() {
        runLineCount()
        runLineLookup()
        runLineStarts()
        runEdgeCases()

        if !failures.isEmpty {
            fputs("\(failures.count) check(s) failed\n", stderr)
            exit(1)
        }
        print("ok - \(passed) source line index checks passed")
    }
}

private func runLineCount() {
    expectEqual(SourceLineIndex("").count, 1, "空文本算 1 行")
    expectEqual(SourceLineIndex("a").count, 1, "单行无换行算 1 行")
    expectEqual(SourceLineIndex("a\n").count, 2, "文末换行多出一个空行")
    expectEqual(SourceLineIndex("a\n\n").count, 3, "连续换行逐行计数")
    expectEqual(SourceLineIndex("a\nb\nc").count, 3, "多行计数")
    expectEqual(SourceLineIndex("\n").count, 2, "单个换行算 2 行")
}

private func runLineLookup() {
    let text = "first\nsecond\n\nfourth"
    let index = SourceLineIndex(text)
    let ns = text as NSString

    expectEqual(index.line(ofCharacter: 0), 0, "首字符在第 1 行")
    expectEqual(index.line(ofCharacter: ns.range(of: "first").location), 0, "首行内容仍属第 1 行")
    expectEqual(index.line(ofCharacter: ns.range(of: "second").location), 1, "second 在第 2 行")
    expectEqual(index.line(ofCharacter: ns.range(of: "fourth").location), 3, "空行之后的 fourth 在第 4 行")

    // 每行的首字符与末字符都必须落在本行内——行号栏和高亮都依赖这条。
    var allWithinLine = true
    for entry in laidOutLines(text) {
        let start = entry.start
        let end = entry.start + entry.length - 1
        if end < start { continue }
        if index.line(ofCharacter: start) != entry.line || index.line(ofCharacter: end) != entry.line {
            allWithinLine = false
        }
    }
    check("每行首末字符都归属本行", allWithinLine, "行边界与实际换行位置不一致")
}

private func runLineStarts() {
    let index = SourceLineIndex("a\nbb\nccc")
    expectEqual(index.start(ofLine: 0), 0, "第 1 行行首为 0")
    expectEqual(index.start(ofLine: 1), 2, "第 2 行行首紧随第 1 行换行")
    expectEqual(index.start(ofLine: 2), 5, "第 3 行行首紧随第 2 行换行")

    // 行首下标必须单调递增，否则高亮扩行时会取到错误的范围。
    var monotonic = true
    var previous = -1
    for line in 0..<index.count {
        let start = index.start(ofLine: line)
        if start <= previous { monotonic = false }
        previous = start
    }
    check("行首下标单调递增", monotonic, "start(ofLine:) 未随行号递增")
}

private func runEdgeCases() {
    // CRLF：行内含 \r，但逻辑行边界仍由 \n 决定。
    let crlf = SourceLineIndex("a\r\nb")
    expectEqual(crlf.count, 2, "CRLF 文本按 2 行计算")
    expectEqual(crlf.line(ofCharacter: 0), 0, "CRLF 首行归属正确")
    expectEqual(crlf.line(ofCharacter: 3), 1, "CRLF 换行后的字符落到第 2 行")

    // 多字节字符：行首下标是 utf16 下标，与 NSTextView 一致。
    let emoji = SourceLineIndex("中文\n🎉")
    expectEqual(emoji.count, 2, "多字节文本行数正确")
    expectEqual(emoji.line(ofCharacter: 2), 0, "中文字符下标仍在第 1 行")
    expectEqual(emoji.line(ofCharacter: 3), 1, "emoji 起始下标落到第 2 行")

    // 越界下标夹取，不崩溃也不越界返回。
    let index = SourceLineIndex("a\nb")
    expectEqual(index.line(ofCharacter: -5), 0, "负下标夹到首行")
    expectEqual(index.line(ofCharacter: 9999), 1, "超长下标夹到末行")
    expectEqual(index.start(ofLine: -1), 0, "负行号夹到首行行首")
    expectEqual(index.start(ofLine: 99), index.start(ofLine: 1), "超界行号夹到末行行首")

    // 大文档：行数与实际换行个数一致（分块渲染的大文件会走到这里）。
    let big = (0..<50_000).map { "line \($0)" }.joined(separator: "\n")
    expectEqual(SourceLineIndex(big).count, 50_000, "5 万行文档行数准确")
}
