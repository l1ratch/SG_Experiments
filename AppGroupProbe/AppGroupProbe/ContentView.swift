import SwiftUI
import WidgetKit

// MARK: - ContentView
//
// Диагностический экран AppGroupProbe. Показывает фактическое состояние
// доступа к App Group этого процесса и результат межпроцессного обмена
// данными с виджетом. Никаких фиктивных контейнеров: каждая ошибка
// отображается как есть.

struct ContentView: View {

    // MARK: State

    @State private var containerURLText: String = "—"
    @State private var containerAccessText: String = "—"
    @State private var payloadText: String = "—"
    @State private var statusText: String = "Готово к проверке"
    @State private var lastErrorText: String = "—"
    @State private var widgetReloadText: String = "—"

    var body: some View {
        NavigationStack {
            Form {
                Section("Идентичность процесса") {
                    row("Bundle ID", ProbeConfig.bundleIdentifier)
                    row("App Group", ProbeConfig.appGroupIdentifier.isEmpty ? "(отсутствует в Info.plist!)" : ProbeConfig.appGroupIdentifier)
                }

                Section("Общий контейнер (системный API)") {
                    row("containerURL", containerURLText)
                    row("Доступ", containerAccessText)
                }

                Section("Данные в App Group") {
                    Text(payloadText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }

                Section("Тест обмена с виджетом") {
                    Button("Записать тестовые данные") {
                        writeTestData()
                    }
                    Button("Перечитать данные") {
                        readBack()
                    }
                    Button("Обновить виджет (WidgetCenter)") {
                        reloadWidget()
                    }
                    row("Перезагрузка виджета", widgetReloadText)
                }

                Section("Диагностика") {
                    row("Статус", statusText)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Последняя ошибка")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lastErrorText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("Файл: \(ProbeStore.relativePath)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AppGroupProbe")
            .onAppear {
                refreshDiagnostics()
            }
        }
    }

    // MARK: - Helpers

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func refreshDiagnostics() {
        let groupID = ProbeConfig.appGroupIdentifier
        if groupID.isEmpty {
            containerURLText = "—"
            containerAccessText = "❌ AppGroupIdentifier не задан"
            statusText = "Конфигурация сборки сломана"
            lastErrorText = ProbeError.missingGroupID.description
            return
        }
        if let url = ProbeConfig.containerURL {
            containerURLText = url.path
            containerAccessText = "✅ контейнер получен (право на группу есть)"
        } else {
            containerURLText = "nil"
            containerAccessText = "❌ контейнер недоступен (права нет)"
            statusText = "App Group не выдана этому процессу"
            lastErrorText = ProbeError.containerUnavailable(groupID: groupID).description
        }
        readBack()
    }

    private func writeTestData() {
        switch ProbeStore.writeNewGeneration() {
        case .success(let payload):
            statusText = "✅ Записано поколение #\(payload.generation)"
            lastErrorText = "—"
            payloadText = describe(payload: payload)
            // Просим WidgetKit обновить timeline сразу после записи.
            WidgetCenter.shared.reloadTimelines(ofKind: "AppGroupProbeWidget")
            widgetReloadText = "запрошена (после записи)"
        case .failure(let error):
            statusText = "❌ Запись не удалась"
            lastErrorText = error.description
            refreshDiagnostics()
        }
    }

    private func readBack() {
        switch ProbeStore.read() {
        case .success(let payload):
            payloadText = describe(payload: payload)
            statusText = "✅ Данные прочитаны из общего контейнера"
            lastErrorText = "—"
        case .failure(let error):
            payloadText = "—"
            if case .fileNotFound = error {
                statusText = "Файл ещё не записан — нажмите «Записать тестовые данные»"
            } else {
                statusText = "❌ Чтение не удалось"
            }
            lastErrorText = error.description
        }
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: "AppGroupProbeWidget")
        widgetReloadText = "запрошена вручную \(Date.formattedShortNow())"
    }

    private func describe(payload: ProbePayload) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return [
            "uuid:        \(payload.uuid)",
            "generation:  \(payload.generation)",
            "writtenAt:   \(formatter.string(from: payload.writtenAt)) (local)",
            "writer:      \(payload.writer)",
        ].joined(separator: "\n")
    }
}

extension Date {
    static func formattedShortNow() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
