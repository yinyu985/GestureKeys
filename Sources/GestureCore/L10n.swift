import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans", english = "en"

    // Keep the interface preference separate from exported rules and macOS's language settings.
    private static let preferenceKey = "GestureKeysInterfaceLanguage"

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .simplifiedChinese
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
    public var locale: Locale { Locale(identifier: rawValue) }
}

public enum L10n {
    private static let resources = Bundle.main.url(forResource: "GestureKeys_GestureCore", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    private static let localizedBundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.allCases.map { language in
        let bundle = resources.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? resources
        return (language, bundle)
    })

    /// Format keys use positional string arguments. Inserted text, including rule names, is never translated.
    public static func text(_ key: String, _ values: String...) -> String {
        let bundle = localizedBundles[AppLanguage.load()] ?? resources
        let translated = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !values.isEmpty else { return translated }
        return String(format: translated, arguments: values)
    }
}
