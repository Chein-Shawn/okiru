import Foundation

enum AppLanguage {
    static let choices: [(String,String)] = [("system","System"),("en","English"),("zh-Hant","繁體中文"),("zh-Hans","简体中文"),("yue","粵語"),("ja","日本語"),("ko","한국어"),("es","Español"),("fr","Français"),("de","Deutsch"),("it","Italiano"),("pt-BR","Português (Brasil)"),("ru","Русский"),("ar","العربية"),("id","Bahasa Indonesia"),("th","ไทย"),("vi","Tiếng Việt"),("tr","Türkçe"),("hi","हिन्दी"),("pl","Polski"),("nl","Nederlands")]
    static var selected: String { UserDefaults(suiteName: SharedRestrictionStore.groupID)?.string(forKey: "language") ?? UserDefaults.standard.string(forKey:"language") ?? "system" }
    static var effective: String {
        selected == "system" ? Bundle.main.preferredLocalizations.first ?? "en" : selected
    }
}

func tr(_ key: String) -> String {
    let language = AppLanguage.effective
    if let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
    return Bundle.main.localizedString(forKey:key, value:nil, table:nil)
}

func tf(_ key: String, _ arguments: CVarArg...) -> String {
    String(format:tr(key),locale:Locale(identifier:AppLanguage.effective),arguments:arguments)
}

func displayDate(_ value: Date, date: Date.FormatStyle.DateStyle = .abbreviated,
                 time: Date.FormatStyle.TimeStyle = .shortened, timeZoneID: String? = nil) -> String {
    var style = Date.FormatStyle(date:date,time:time).locale(Locale(identifier:AppLanguage.effective))
    if let timeZoneID, let zone = TimeZone(identifier:timeZoneID) { style.timeZone = zone }
    return value.formatted(style)
}

struct DisplayError: LocalizedError {
    let key: String
    var errorDescription: String? { tr(key) }
}
