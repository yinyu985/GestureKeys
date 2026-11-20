import Foundation

public enum L10n {
    private static let localizedBundle: Bundle = {
        let resources = Bundle.main.url(forResource: "GestureKeys_GestureCore", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        let preferences = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        let language = Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: preferences).first ?? "zh-Hans"
        return resources.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? resources
    }()

    /// Format keys use positional string arguments. Inserted text, including rule names, is never translated.
    public static func text(_ key: String, _ values: String...) -> String {
        let translated = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard !values.isEmpty else { return translated }
        return String(format: translated, arguments: values)
    }
}
