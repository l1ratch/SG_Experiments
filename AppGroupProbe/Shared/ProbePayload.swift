import Foundation

// MARK: - ProbePayload
//
// Данные, которыми обмениваются основной процесс (приложение) и процесс
// Widget Extension через общий системный контейнер App Group.
// Оба таргета компилируют этот файл — чтение и запись идут через один
// и тот же код и один и тот же файл, т.е. обмен является межпроцессным.

public struct ProbePayload: Codable, Equatable {
    public let uuid: String
    /// Номер поколения: каждое запись из приложения инкрементирует счётчик.
    public let generation: Int
    /// Время записи (UTC).
    public let writtenAt: Date
    /// Идентификатор записавшего процесса — в прототипе всегда "app".
    public let writer: String

    public init(uuid: String, generation: Int, writtenAt: Date, writer: String) {
        self.uuid = uuid
        self.generation = generation
        self.writtenAt = writtenAt
        self.writer = writer
    }
}

// MARK: - ProbeError

public enum ProbeError: Error, CustomStringConvertible {
    /// В Info.plist не подставился AppGroupIdentifier (сломана конфигурация сборки).
    case missingGroupID
    /// containerURL вернул nil: процессу не выдано право на группу
    /// (профиль/подпись/entitlements не согласованы).
    case containerUnavailable(groupID: String)
    /// Ошибка записи в общий контейнер (с текстом системной ошибки).
    case writeFailed(String)
    /// Файл ещё не создан — приложение не записывало данные.
    case fileNotFound(String)
    /// Ошибка чтения файла (права доступа и т.п.).
    case readFailed(String)
    /// Файл есть, но содержимое не декодируется (чужие/битые данные).
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .missingGroupID:
            return "AppGroupIdentifier отсутствует в Info.plist — проверьте Probe.xcconfig"
        case .containerUnavailable(let groupID):
            return "containerURL == nil для «\(groupID)»: группе нет права в подписи/профиле"
        case .writeFailed(let message):
            return "Ошибка записи: \(message)"
        case .fileNotFound(let path):
            return "Файл не найден (запишите данные из приложения): \(path)"
        case .readFailed(let message):
            return "Ошибка чтения: \(message)"
        case .decodeFailed(let message):
            return "Ошибка декодирования JSON: \(message)"
        }
    }
}

// MARK: - ProbeStore

public enum ProbeStore {

    /// Имя тестового файла внутри namespace-подкаталога общего контейнера.
    public static let fileName = "probe-token.json"

    /// Полный путь к файлу. nil, если контейнер недоступен.
    public static var fileURL: URL? {
        guard let container = ProbeConfig.containerURL else { return nil }
        return container
            .appendingPathComponent(ProbeConfig.namespaceName)
            .appendingPathComponent(fileName)
    }

    /// Относительный путь внутри контейнера (для диагностики).
    public static var relativePath: String {
        "\(ProbeConfig.namespaceName)/\(fileName)"
    }

    // MARK: Чтение

    public static func read() -> Result<ProbePayload, ProbeError> {
        let groupID = ProbeConfig.appGroupIdentifier
        if groupID.isEmpty {
            return .failure(.missingGroupID)
        }
        guard let url = fileURL else {
            return .failure(.containerUnavailable(groupID: groupID))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.fileNotFound(relativePath))
        }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(ProbePayload.self, from: data)
            return .success(payload)
        } catch let error as DecodingError {
            return .failure(.decodeFailed(String(describing: error)))
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }
    }

    // MARK: Запись

    /// Записывает новое поколение данных: случайный UUID + инкремент счётчика.
    /// Возвращает записанный payload или диагностическую ошибку.
    public static func writeNewGeneration() -> Result<ProbePayload, ProbeError> {
        let groupID = ProbeConfig.appGroupIdentifier
        if groupID.isEmpty {
            return .failure(.missingGroupID)
        }
        guard let url = fileURL else {
            return .failure(.containerUnavailable(groupID: groupID))
        }

        // Предыдущее поколение (для счётчика). Ошибки чтения не блокируют
        // запись — это диагностируется отдельно.
        let previousGeneration: Int
        switch read() {
        case .success(let payload):
            previousGeneration = payload.generation
        case .failure:
            previousGeneration = 0
        }

        let payload = ProbePayload(
            uuid: UUID().uuidString,
            generation: previousGeneration + 1,
            writtenAt: Date(),
            writer: "app"
        )

        do {
            let directoryURL = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: [.atomic])
            // Контрольная запись: немедленно читаем назад тем же кодом.
            switch read() {
            case .success:
                return .success(payload)
            case .failure(let error):
                return .failure(error)
            }
        } catch {
            let nsError = error as NSError
            return .failure(.writeFailed("\(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))"))
        }
    }
}
