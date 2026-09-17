import Foundation
import Combine

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("not ok - \(message)\n", stderr)
        exit(1)
    }
}

@main
struct DocStateLanguageTests {
    @MainActor
    static func main() {
        let suiteName = "mdreview.reactive-language-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferredLanguages = ["en-US"]
        let state = DocState(defaults: defaults) { preferredLanguages }

        expect(state.language == .system, "missing preference selects Follow System")
        expect(state.resolvedLanguage == .english, "non-Chinese system resolves to English")

        preferredLanguages = ["zh-Hans-CN"]
        state.refreshSystemLanguage()
        expect(state.resolvedLanguage == .chinese, "Follow System reacts to Chinese system language")

        state.setLanguage(.english)
        preferredLanguages = ["zh-Hant-TW"]
        state.refreshSystemLanguage()
        expect(state.resolvedLanguage == .english, "manual English ignores system language changes")

        state.setLanguage(.system)
        expect(state.resolvedLanguage == .chinese, "returning to Follow System resolves immediately")
        expect(
            defaults.string(forKey: AppLanguage.defaultsKey) == AppLanguage.system.rawValue,
            "Follow System mode persists"
        )

        let restored = DocState(defaults: defaults) { ["en-US"] }
        expect(restored.language == .system, "persisted Follow System mode restores")
        expect(restored.resolvedLanguage == .english, "restored Follow System uses current system language")

        state.setLanguage(.chinese)
        let restoredChinese = DocState(defaults: defaults) { ["en-US"] }
        expect(restoredChinese.language == .chinese, "persisted Chinese mode restores")
        expect(restoredChinese.resolvedLanguage == .chinese, "restored Chinese ignores current system language")

        state.setLanguage(.english)
        let restoredEnglish = DocState(defaults: defaults) { ["zh-Hans"] }
        expect(restoredEnglish.language == .english, "persisted English mode restores")
        expect(restoredEnglish.resolvedLanguage == .english, "restored English ignores current system language")

        defaults.removeObject(forKey: AppLanguage.defaultsKey)
        let sameResolutionState = DocState(defaults: defaults) { ["en-US"] }
        var publishedModes: [AppLanguage] = []
        let modeCancellable = sameResolutionState.$language
            .dropFirst()
            .sink { publishedModes.append($0) }
        var resolvedNotifications = 0
        let notificationToken = NotificationCenter.default.addObserver(
            forName: .mdreviewLanguageChanged,
            object: nil,
            queue: nil
        ) { _ in
            resolvedNotifications += 1
        }
        sameResolutionState.setLanguage(.english)
        sameResolutionState.setLanguage(.system)
        expect(publishedModes == [.english, .system], "mode publishes even when resolved language stays English")
        expect(resolvedNotifications == 0, "same resolved language does not publish a false language change")
        withExtendedLifetime(modeCancellable) {}
        NotificationCenter.default.removeObserver(notificationToken)

        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        var legacyOverrideWasPresentDuringResolution = false
        let migrated = DocState.makeApplicationState(defaults: defaults) {
            legacyOverrideWasPresentDuringResolution = defaults
                .persistentDomain(forName: suiteName)?["AppleLanguages"] != nil
            return ["en-US"]
        }
        expect(!legacyOverrideWasPresentDuringResolution, "legacy override clears before system language resolution")
        expect(
            defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil,
            "legacy override is removed from the application domain"
        )
        expect(migrated.resolvedLanguage == .english, "migration resolves the current system language")

        print("ok - reactive language state")
    }
}
