import Foundation

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("not ok - \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct AboutLinksTests {
    static func main() {
        expectEqual(AboutLinks.githubProject.absoluteString,
                    "https://github.com/allanzhang/MDReview",
                    "GitHub project URL")
        print("ok - about links tests")
    }
}
