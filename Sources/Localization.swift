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

    /// lproj Bundle 只解析一次。localizedValue 被 MainMenuLocalizer 对每个菜单项调用几十次，
    /// 每次都 bundle.path(forResource:) 走一遍文件系统，是单次全量改写要 30~80ms 的主因。
    nonisolated(unsafe) private static var lprojBundles: [String: Bundle] = [:]
    private static let lprojLock = NSLock()

    private static func lproj(_ resource: String, of bundle: Bundle) -> Bundle? {
        let key = bundle.bundlePath + "|" + resource
        lprojLock.lock()
        let cached = lprojBundles[key]
        lprojLock.unlock()
        if let cached { return cached }
        guard let path = bundle.path(forResource: resource, ofType: "lproj"),
              let lprojBundle = Bundle(path: path) else { return nil }
        lprojLock.lock()
        lprojBundles[key] = lprojBundle
        lprojLock.unlock()
        return lprojBundle
    }

    private static func localizedValue(for key: String, language: AppLanguage, bundle: Bundle) -> String? {
        let resource = language == .chinese ? "zh-Hans" : "en"
        guard let localizedBundle = lproj(resource, of: bundle) else {
            return nil
        }
        let value = localizedBundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? nil : value
    }
}
