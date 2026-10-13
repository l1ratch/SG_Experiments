import Foundation

// MARK: - ProbeConfig
//
// Единый источник конфигурации для основного приложения и Widget Extension.
// Идентификатор App Group приходит из Info.plist каждого bundle (ключ
// AppGroupIdentifier), куда он подставляется на этапе сборки из общего
// значения PROBE_APP_GROUP_ID в project.yml. Группа НЕ вычисляется из Bundle ID.

public enum ProbeConfig {

    /// App Group Identifier, явно выбранный в Probe.xcconfig.
    public static var appGroupIdentifier: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Bundle ID текущего процесса (app или widget) — для диагностики.
    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "(unknown)"
    }

    /// Namespace-подкаталог внутри общего контейнера. Стабильное имя
    /// уменьшает риск коллизий с другими приложениями, использующими ту же
    /// разрешённую группу (см. docs/appgroup-redirection-research.md).
    public static let namespaceName = "AppGroupProbe"

    /// Системный URL общего контейнера. Для неразрешённой группы iOS
    /// возвращает nil — это и есть главный диагностический признак.
    /// Никаких фиктивных путей в Documents/Library вместо настоящего контейнера.
    public static var containerURL: URL? {
        guard !appGroupIdentifier.isEmpty else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }
}
