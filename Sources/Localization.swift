import Foundation

enum L10n {
    static var currentLanguage: AppLanguage {
        AppLanguage.load(from: UserDefaults.standard.string(forKey: AppLanguage.defaultsKey))
            .resolved(preferredLanguages: SystemLanguage.preferredLanguages())
    }

    static func string(_ key: String, language: AppLanguage, bundle: Bundle = .main) -> String {
        let resolved = language.resolved()
        if let value = localizedValue(for: key, language: resolved, bundle: bundle), !value.isEmpty {
            return value
        }
        if resolved != .english,
           let fallback = localizedValue(for: key, language: .english, bundle: bundle),
           !fallback.isEmpty {
            return fallback
        }
        return key
    }

    static func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        let template = string(key, language: language)
        return String(format: template, locale: language.resolved().locale, arguments: arguments)
    }

    private static func localizedValue(for key: String, language: AppLanguage, bundle: Bundle) -> String? {
        let resource = language == .chinese ? "zh-Hans" : "en"
        guard let path = bundle.path(forResource: resource, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return nil
        }
        let value = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }
}
