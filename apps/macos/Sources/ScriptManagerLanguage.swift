import Foundation

enum ScriptManagerLanguage {
    case english, chinese

    static let initial = preferred

    static var preferred: ScriptManagerLanguage { codexPreference ?? systemPreference }
    static var systemPreference: ScriptManagerLanguage { ScriptManagerLanguage(locale: Locale.preferredLanguages.first) }

    static var codexPreference: ScriptManagerLanguage? {
        struct Settings: Decodable { let locale: String? }

        let settings = CodexProjectCatalog.codexHome.appendingPathComponent("computer-use/config.json")
        guard let data = try? Data(contentsOf: settings),
              let locale = (try? JSONDecoder().decode(Settings.self, from: data))?.locale,
              !locale.isEmpty else { return nil }
        return ScriptManagerLanguage(locale: locale)
    }

    init(locale: String?) {
        let language = locale?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        self = language == "zh" ? .chinese : .english
    }

    func text(_ english: String, _ chinese: String) -> String {
        self == .chinese ? chinese : english
    }

    var appTitle: String { text("Script Manager", "脚本管理") }
    var openProjectTitle: String { text("Open Project Folder", "打开项目目录") }
}
