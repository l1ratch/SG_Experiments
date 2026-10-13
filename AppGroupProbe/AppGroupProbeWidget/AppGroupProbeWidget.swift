import WidgetKit
import SwiftUI

// MARK: - Timeline Entry
//
// Виджет ЧИТАЕТ файл, записанный основным приложением, через тот же
// системный API containerURL(forSecurityApplicationGroupIdentifier:).
// Статический текст или собственное хранилище не используются: это
// настоящий межпроцессный тест.

struct ProbeEntry: TimelineEntry {
    let date: Date
    let state: EntryState

    enum EntryState {
        case ok(ProbePayload)
        case containerUnavailable(String)
        case noData(String)
        case failed(String)
    }
}

// MARK: - Provider

struct ProbeProvider: TimelineProvider {

    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: Date(), state: .noData("Запишите данные из приложения"))
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        let entry = currentEntry()
        // Один entry; следующее обновление — через 30 минут или по
        // WidgetCenter.reloadTimelines из приложения.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> ProbeEntry {
        switch ProbeStore.read() {
        case .success(let payload):
            return ProbeEntry(date: Date(), state: .ok(payload))
        case .failure(let error):
            switch error {
            case .missingGroupID:
                return ProbeEntry(date: Date(), state: .failed("Нет AppGroupIdentifier в Info.plist"))
            case .containerUnavailable:
                return ProbeEntry(date: Date(), state: .containerUnavailable(ProbeConfig.appGroupIdentifier))
            case .fileNotFound:
                return ProbeEntry(date: Date(), state: .noData("Запишите данные из приложения"))
            case .readFailed(let message), .decodeFailed(let message), .writeFailed(let message):
                return ProbeEntry(date: Date(), state: .failed(message))
            }
        }
    }
}

// MARK: - Widget Views

struct ProbeEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ProbeEntry

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Color(white: 0.12)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.state {
        case .ok(let payload):
            okView(payload)
        case .containerUnavailable(let groupID):
            statusView(
                title: "App Group недоступна",
                subtitle: "containerURL == nil",
                detail: "Виджету не выдано право на «\(groupID)». Проверь подпись расширения после GBox."
            )
        case .noData(let message):
            statusView(
                title: "Нет данных",
                subtitle: message,
                detail: "Контейнер доступен, но файл \(ProbeStore.relativePath) ещё не создан приложением."
            )
        case .failed(let message):
            statusView(
                title: "Ошибка чтения",
                subtitle: message,
                detail: ProbeStore.relativePath
            )
        }
    }

    private func okView(_ payload: ProbePayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("App Group OK")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if family == .systemSmall {
                Text(payload.uuid)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            } else {
                Text(payload.uuid)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Поколение #\(payload.generation) · записано \(payload.writtenAt, style: .relative) назад")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func statusView(title: String, subtitle: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Widget

struct ProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AppGroupProbeWidget", provider: ProbeProvider()) { entry in
            ProbeEntryView(entry: entry)
        }
        .configurationDisplayName("AppGroupProbe")
        .description("Читает маркер, записанный приложением, из App Group.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AppGroupProbeWidgetBundle: WidgetBundle {
    var body: some Widget {
        ProbeWidget()
    }
}
