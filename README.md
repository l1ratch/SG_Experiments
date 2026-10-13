# SG_Experiments

Рабочий репозиторий экспериментов со Swiftgram. Первый проект — **AppGroupProbe**:
минимальный тест App Groups при sideload-подписи через GBox.

> ⚠️ Репозиторий не содержит Swiftgram и его исходников — эксперименты
> независимы (требование: не смешивать).

---

## AppGroupProbe — что это

Минимальное iOS-приложение (SwiftUI) + WidgetKit Extension, которые проверяют
на реальном устройстве:

1. Доступ основного приложения к App Group, разрешённой provisioning profile;
2. Доступ Widget Extension к той же группе;
3. **Настоящий обмен данными между двумя процессами** через общий системный
   контейнер (uuid + номер поколения, записанные приложением, читает виджет);
4. Что происходит с правами после переподписи IPA в GBox;
5. Работает ли виджет с текущим профилем без выпуска новых сертификатов.

Никаких фиктивных контейнеров: только системный
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`,
любая ошибка показывается как есть.

## Конфигурация (профиль EYD9KX)

Один явный выбор, зафиксированный в [`AppGroupProbe/project.yml`](AppGroupProbe/project.yml):

| Параметр | Значение | Источник |
|---|---|---|
| Main Bundle ID | `app.yam53.taro5888` | explicit App ID профиля |
| Widget Bundle ID | `app.yam53.taro5888.widget` | суффикс main; GBox применяет main-profile к расширениям |
| App Group | `group.c2fefdd0db2e255e.1` | первая из пяти разрешённых групп профиля |

Все три значения задаются в **одном** месте `project.yml`: `settings.base`
(общий для всех таргетов `PROBE_APP_GROUP_ID`) и `PRODUCT_BUNDLE_IDENTIFIER`
в настройках таргетов. Группа подставляется в Info.plist каждого bundle
(ключ `AppGroupIdentifier`) при сборке — код читает её из Info.plist и
**не вычисляет из Bundle ID**. Та же группа задана в entitlements обоих
таргетов (audit-скрипт проверяет совпадение).

Изменение конфигурации:
- в репозитории — правь `project.yml` (значение `PROBE_APP_GROUP_ID` **и**
  entitlements-блоки у обоих таргетов — держи их синхронными);
- разовая сборка — параметры `bundle_id` / `app_group` при ручном запуске
  workflow (они подставляются в spec перед генерацией проекта).

## Структура

```text
SG_Experiments/
├── .github/workflows/build-appgroup-probe.yml   # CI: сборка unsigned IPA
├── AppGroupProbe/
│   ├── project.yml                              # XcodeGen-спецификация + конфигурация идентичности
│   ├── AppGroupProbe/                           # main app (SwiftUI)
│   ├── AppGroupProbeWidget/                     # WidgetKit extension
│   └── Shared/                                  # код, компилируемый в оба таргета
├── scripts/audit-ipa.sh                         # аудит IPA (macOS)
├── docs/
│   ├── testing-checklist.md                     # чек-лист тестирования на iPhone
│   └── appgroup-redirection-research.md         # TGExtra/ipapatch/zxPluginsInject
└── README.md
```

`Shared/` — источник межпроцессной честности теста: `ProbePayload.swift`
(чтение/запись `probe-token.json` в общем контейнере) компилируется в оба
таргета, поэтому виджет читает файл **другого процесса** тем же кодом.

## Сборка

### GitHub Actions (основной путь — локального Mac нет)

Workflow [`build-appgroup-probe.yml`](.github/workflows/build-appgroup-probe.yml):

- триггеры: ручной (`workflow_dispatch`, с опциональными `bundle_id` /
  `app_group`) и автоматический (push в `AppGroupProbe/**`, `scripts/**`);
- macOS runner, свежий Xcode;
- `xcodegen` генерирует `.xcodeproj` из `project.yml` (сам проект в git не
  хранится);
- `xcodebuild` собирает main + widget **без подписи**
  (`CODE_SIGNING_ALLOWED=NO`);
- ad-hoc подпись (`codesign -s -`) встраивает entitlements в бинарники —
  чтобы GBox при переподписи видел заявленные App Groups;
- упаковка `Payload/` → `AppGroupProbe-unsigned.ipa`;
- [`scripts/audit-ipa.sh`](scripts/audit-ipa.sh) проверяет структуру
  (жёсткий гейт: `.app` + `.appex` обязаны присутствовать);
- артефакты: `AppGroupProbe-unsigned-ipa` (сама IPA) и
  `AppGroupProbe-audit-report` (отчёт аудита; при ошибках сборки сырой лог
  выводится прямо в шаге build).

**Секретов в CI нет** — ни `.p12`, ни паролей, ни профилей. IPA выходит
неподписанной; подпись ставит GBox на устройстве.

### Локальная сборка на Mac (эквивалент CI)

```sh
brew install xcodegen
cd AppGroupProbe
xcodegen generate
xcodebuild -project AppGroupProbe.xcodeproj -target AppGroupProbe \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

APP=$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name "*.app")
codesign --force --sign - --entitlements AppGroupProbeWidget/AppGroupProbeWidget.entitlements "$APP/PlugIns/AppGroupProbeWidget.appex"
codesign --force --sign - --entitlements AppGroupProbe/AppGroupProbe.entitlements "$APP"
mkdir Payload && cp -R "$APP" Payload/ && zip -qry ../AppGroupProbe-unsigned.ipa Payload
```

## Подпись через GBox и установка

1. Скачай артефакт `AppGroupProbe-unsigned-ipa` (файл
   `AppGroupProbe-unsigned.ipa`) из запуска workflow.
2. Импортируй IPA в GBox.
3. Подпиши **своим сертификатом и профилем** (тот, что содержит App Groups).
   Если GBox предлагает опции — включай сохранение расширений (extensions),
   не включай удаление PlugIns.
4. Установи на iPhone.
5. Действуй по [docs/testing-checklist.md](docs/testing-checklist.md).

⚠️ Перед первой установкой учти: explicit App ID `app.yam53.taro5888` —
если на устройстве уже стоит приложение с этим Bundle ID, установка заменит
его (installation identity), см. отчёт, стр. 14.

### Что сравнивать до/после GBox

Если GBox умеет экспортировать переподписанную IPA — прогони
`scripts/audit-ipa.sh` по обеим версиям и сверь (таблица в чек-листе):

1. App Groups в entitlements main/widget — сохранились?;
2. application-identifier каждого bundle — что поставил GBox?;
3. embedded.mobileprovision — какой профиль и куда встроен;
4. структура PlugIns — расширение на месте?;
5. codesign --verify для каждого bundle.

## Диагностика ошибок

| Симптом | Вероятная причина | Что делать |
|---|---|---|
| Приложение не ставится | device coverage / срок профиля / identity | Сверь UDID устройства и профиль; проверь срок в audit-отчёте |
| `containerURL == nil` в приложении | GBox не перенёс App Group в entitlements main | Сравни entitlements до/после (audit); попробуй включить опцию сохранения entitlements в GBox |
| Виджета нет в галерее | .appex не установлен/не подписан/не зарегистрирован | Audit: .appex в PlugIns? codesign verify виджета? Bundle ID виджета корректен? |
| Виджет есть, но «App Group недоступна» | entitlements виджета потеряли группу при переподписи расширения | Audit переподписанной IPA: App Groups у .appex; GBox может подписывать расширения отдельно |
| Виджет: «Нет данных» | Контейнер есть, файла нет | Нажми «Записать тестовые данные» в приложении, затем «Обновить виджет» |
| Виджет не обновляется мгновенно | Политика timeline (30 мин) | Подожди; мгновенность не критерий — uuid из файла важнее |
| Разные uuid в app и виджете | Процессы попали в разные контейнеры/группы | Проверь `AppGroupIdentifier` в обоих Info.plist (audit) и фактические entitlements |

## Перенос на Swiftgram — заключение

Схема переносима **только после** успешного прохождения чек-листа (все 7
критериев). План переноса (по отчёту, стр. 15):

1. Зафиксировать входы: commit Swiftgram `cf8b23be`, toolchain, версии;
2. Ввести независимую конфигурацию: `shared_app_group_id` (явная группа),
   `deployment_namespace`, `main_bundle_id` — вместо вычисления
   `group.<bundle-id>`;
3. Централизованный resolver группы (публичный API, без угадывания путей);
4. Заменить **все** потребители: main, WidgetKit, WidgetItems, Share,
   NotificationService/Content, Siri, Broadcast, SGSimpleSettings,
   reset/log/debug — не только `SGAppGroupIdentifier`;
5. Packaging gate: для каждого bundle сверять entitlements/профиль/runtime;
6. Миграцию данных проектировать отдельно (не трогать `.tempkey`);
7. Принимать результат по ступеням: build → audit → install → cold launch →
   sharing → widget → push.

Если чек-лист провалится из-за GBox (группы теряются при переподписи) —
следующий шаг: минимальный compatibility shim по принципу zxPluginsInject
(редирект только старого идентификатора в разрешённую группу, без глобальной
подмены Bundle ID), см.
[docs/appgroup-redirection-research.md](docs/appgroup-redirection-research.md).
До провала shim не внедряется.
