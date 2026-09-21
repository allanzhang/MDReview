import AppKit

/// 把拖入/粘贴板里的文件项解析成可打开的 Markdown URL。
/// Finder 在 macOS 上可能给出 URL、file URL Data，或 `file://` / POSIX 路径字符串。
enum MarkdownFileDrop {
    static let pathExtensions: Set<String> = ["md", "markdown"]

    static func isMarkdown(_ url: URL) -> Bool {
        pathExtensions.contains(url.pathExtension.lowercased())
    }

    static func url(fromLoadedItem item: Any?) -> URL? {
        guard let candidate = candidateURL(fromLoadedItem: item) else { return nil }
        return isMarkdown(candidate) ? candidate : nil
    }

    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter(isMarkdown)
    }

    static func firstURL(from pasteboard: NSPasteboard) -> URL? {
        urls(from: pasteboard).first
    }

    private static func candidateURL(fromLoadedItem item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let string = String(data: data, encoding: .utf8) {
                return url(fromFileString: string)
            }
            return nil
        }
        if let string = item as? String {
            return url(fromFileString: string)
        }
        if let string = item as? NSString {
            return url(fromFileString: string as String)
        }
        return nil
    }

    private static func url(fromFileString string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file:") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
    }
}
