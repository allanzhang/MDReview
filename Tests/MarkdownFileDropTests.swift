import AppKit
import Foundation

func expectTrue(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("not ok - \(message)\n", stderr)
        exit(1)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("not ok - \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct MarkdownFileDropTests {
    static func main() {
        let md = URL(fileURLWithPath: "/tmp/notes/demo.md")
        let markdown = URL(fileURLWithPath: "/tmp/notes/demo.markdown")
        let txt = URL(fileURLWithPath: "/tmp/notes/demo.txt")

        expectTrue(MarkdownFileDrop.isMarkdown(md), "md extension is markdown")
        expectTrue(MarkdownFileDrop.isMarkdown(markdown), "markdown extension is markdown")
        expectTrue(!MarkdownFileDrop.isMarkdown(txt), "txt is not markdown")

        expectEqual(MarkdownFileDrop.url(fromLoadedItem: md)?.path, md.path, "URL item")
        expectEqual(MarkdownFileDrop.url(fromLoadedItem: md.absoluteString)?.path, md.path, "file URL string")
        expectEqual(MarkdownFileDrop.url(fromLoadedItem: md.path)?.path, md.path, "POSIX path string")
        expectEqual(MarkdownFileDrop.url(fromLoadedItem: md.absoluteString as NSString)?.path, md.path, "NSString file URL")
        expectEqual(
            MarkdownFileDrop.url(fromLoadedItem: md.absoluteString.data(using: .utf8))?.path,
            md.path,
            "UTF-8 file URL data"
        )
        expectEqual(
            MarkdownFileDrop.url(fromLoadedItem: md.dataRepresentation)?.lastPathComponent,
            "demo.md",
            "URL dataRepresentation"
        )

        expectTrue(MarkdownFileDrop.url(fromLoadedItem: txt) == nil, "reject txt URL")
        expectTrue(MarkdownFileDrop.url(fromLoadedItem: txt.path) == nil, "reject txt path")
        expectTrue(MarkdownFileDrop.url(fromLoadedItem: "not a path") == nil, "reject junk")
        expectTrue(MarkdownFileDrop.url(fromLoadedItem: nil) == nil, "reject nil")

        print("ok - markdown file drop parsing")
    }
}
