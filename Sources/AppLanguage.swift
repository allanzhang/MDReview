import Foundation

enum SystemLanguage {
    static func preferredLanguages(
        defaults: UserDefaults = .standard,
        fallback: [String] = Locale.preferredLanguages
    ) -> [String] {
        preferredLanguages(
            globalDomain: defaults.persistentDomain(forName: UserDefaults.globalDomain),
            fallback: fallback
        )
    }

    static func preferredLanguages(
        globalDomain: [String: Any]?,
        fallback: [String]
    ) -> [String] {
        guard let languages = globalDomain?["AppleLanguages"] as? [String],
              !languages.isEmpty else {
            return fallback
        }
        return languages
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    static let defaultsKey = "mdreview.language"

    var id: String { rawValue }

    static func load(from rawValue: String?) -> AppLanguage {
        rawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func resolved(preferredLanguages: [String] = SystemLanguage.preferredLanguages()) -> AppLanguage {
        switch self {
        case .chinese, .english:
            return self
        case .system:
            guard let preferred = preferredLanguages.first?.lowercased() else {
                return .english
            }
            return preferred.hasPrefix("zh") ? .chinese : .english
        }
    }

    var locale: Locale {
        Locale(identifier: self == .chinese ? "zh-Hans" : "en")
    }
}

extension Notification.Name {
    static let mdreviewLanguageChanged = Notification.Name("mdreview.languageChanged")
}
