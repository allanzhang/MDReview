import Foundation

/// 源码视图的行号索引：记录每一逻辑行的起始字符下标，二分查出任意字符所属行。
///
/// 单独成文件是为了能被 Tests/run.js 单独编译测试——不依赖 AppKit。
/// 语义约定：utf16 下标，与 NSTextView / NSLayoutManager 使用的下标一致。
/// 空文本算 1 行（index.count == 1），"a\n" 算 2 行（末行为空），
/// 与 NSTextView 实际显示的行数一致。
struct SourceLineIndex: Equatable {
    private let starts: [Int]

    /// 逻辑行数（至少为 1）。
    var count: Int { starts.count }

    init(_ text: String) {
        let ns = text as NSString
        var starts: [Int] = [0]
        starts.reserveCapacity(ns.length / 40 + 1)
        var cursor = 0
        while cursor < ns.length {
            let newline = ns.range(of: "\n",
                                   options: [],
                                   range: NSRange(location: cursor, length: ns.length - cursor))
            if newline.location == NSNotFound { break }
            cursor = newline.location + 1
            starts.append(cursor)
        }
        self.starts = starts
    }

    /// 字符下标所属的逻辑行（0 基）。越界下标被夹到有效范围。
    func line(ofCharacter index: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// 该逻辑行的起始字符下标（0 基行号，越界夹取）。
    func start(ofLine line: Int) -> Int {
        starts[min(max(line, 0), starts.count - 1)]
    }
}
