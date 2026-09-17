import Foundation

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("not ok - \(message): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

@main
struct AppLanguageTests {
    static func main() {
        expectEqual(AppLanguage.load(from: nil), .system, "missing preference defaults to system")
        expectEqual(AppLanguage.load(from: "invalid"), .system, "invalid preference defaults to system")
        expectEqual(AppLanguage.load(from: "chinese"), .chinese, "Chinese preference loads")
        expectEqual(AppLanguage.load(from: "english"), .english, "English preference loads")

        expectEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]), .chinese, "zh-Hans resolves to Chinese")
        expectEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .chinese, "zh-Hant resolves to Chinese")
        expectEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US"]), .english, "English resolves to English")
        expectEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .english, "non-Chinese resolves to English")
        expectEqual(AppLanguage.system.resolved(preferredLanguages: []), .english, "empty preferred languages fall back to English")
        expectEqual(AppLanguage.chinese.resolved(preferredLanguages: ["en-US"]), .chinese, "manual Chinese ignores system")
        expectEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english, "manual English ignores system")

        expectEqual(
            SystemLanguage.preferredLanguages(
                globalDomain: ["AppleLanguages": ["zh-Hans-CN"]],
                fallback: ["en-US"]
            ),
            ["zh-Hans-CN"],
            "macOS global language wins over process fallback"
        )
        expectEqual(
            SystemLanguage.preferredLanguages(
                globalDomain: [:],
                fallback: ["en-US"]
            ),
            ["en-US"],
            "missing global language uses process fallback"
        )

        print("ok - app language tests")
    }
}
