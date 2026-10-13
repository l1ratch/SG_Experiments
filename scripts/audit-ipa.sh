#!/bin/bash
#
# audit-ipa.sh — структурный и подписной аудит IPA.
#
# Проверяет для каждого .app / .appex:
#   • Bundle ID и ключевые поля Info.plist (включая AppGroupIdentifier)
#   • Подписанные entitlements (App Groups, application-identifier, aps-environment)
#   • embedded.mobileprovision: App ID, разрешённые группы, срок, устройства
#   • Состояние подписи (codesign --verify)
#   • Консистентность: группа в Info.plist == группе в entitlements ==
#     группам, разрешённым профилем
#
# Работает как с unsigned/ad-hoc IPA из CI (embedded.mobileprovision нет),
# так и с IPA, переподписанной через GBox (профиль и подписи на месте).
#
# Использование: ./audit-ipa.sh <path-to.ipa>
# Требования: macOS с Xcode CLT (codesign, security, plutil, PlistBuddy,
#             unzip, shasum). Для GBox-IPA — тот же скрипт.
#
# Выход: отчёт в stdout. Маркеры APP_MISSING / WIDGET_MISSING используются
# CI-воркфлоу как жёсткий гейт структуры.

set -u

# ---------- Аргументы ----------

IPA_PATH="${1:-}"
if [ -z "$IPA_PATH" ] || [ ! -f "$IPA_PATH" ]; then
    echo "ОШИБКА: укажите путь к IPA: $0 <path-to.ipa>" >&2
    exit 2
fi

WORKDIR=$(mktemp -d /tmp/ipa-audit.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

BOLD=""
RED=""
GREEN=""
YELLOW=""
RESET=""
if [ -t 1 ]; then
    BOLD=$(tput bold 2>/dev/null)
    RED=$(tput setaf 1 2>/dev/null)
    GREEN=$(tput setaf 2 2>/dev/null)
    YELLOW=$(tput setaf 3 2>/dev/null)
    RESET=$(tput sgr0 2>/dev/null)
fi

hr()    { echo "────────────────────────────────────────────────────────────"; }
label() { echo "${BOLD}$1${RESET}"; }

# Читает значение ключа из plist-файла через PlistBuddy.
# $1 = plist, $2 = ключ (двоеточия в пути допустимы: A:B)
plist_get() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# Извлекает все App Group строки из plist-файла:
# plist → JSON → все "group.…" строки.
# (Ключ com.apple.security.application-groups содержит точки, поэтому
#  plutil -extract с keypath тут неприменим.)
groups_from_plist() {
    plutil -convert json -o - "$1" 2>/dev/null \
        | grep -o '"group\.[^"]*"' | tr -d '"' | sort -u
}

# ---------- 1. Распаковка ----------

echo "${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo " АУДИТ IPA: $(basename "$IPA_PATH")"
echo " Дата:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " Размер:    $(stat -f%z "$IPA_PATH" 2>/dev/null || stat -c%s "$IPA_PATH") байт"
echo " SHA-256:   $(shasum -a 256 "$IPA_PATH" | cut -d' ' -f1)"
echo "${BOLD}════════════════════════════════════════════════════════════${RESET}"

unzip -q "$IPA_PATH" -d "$WORKDIR/unpacked" || { echo "${RED}ОШИБКА распаковки IPA${RESET}"; exit 1; }

PAYLOAD="$WORKDIR/unpacked/Payload"
if [ ! -d "$PAYLOAD" ]; then
    echo "${RED}APP_MISSING: в IPA нет каталога Payload/ — это не iOS-приложение${RESET}"
    exit 1
fi

MAIN_APP=$(find "$PAYLOAD" -maxdepth 1 -name "*.app" -type d | head -n 1)
if [ -z "$MAIN_APP" ]; then
    echo "${RED}APP_MISSING: в Payload/ нет основного .app${RESET}"
    exit 1
fi
echo "${GREEN}Основное приложение: $(basename "$MAIN_APP")${RESET}"

# ---------- 2. Список всех bundle ----------

hr
label "Состав IPA (все .app / .appex):"
find "$PAYLOAD" \( -name "*.app" -o -name "*.appex" \) -type d | sort \
    | sed "s|$WORKDIR/unpacked/||"
echo ""

# ---------- 3. Обязательный виджет ----------

WIDGET_APPEX=""
if [ -d "$MAIN_APP/PlugIns" ]; then
    WIDGET_APPEX=$(find "$MAIN_APP/PlugIns" -maxdepth 1 -name "*.appex" -type d | head -n 1)
fi
if [ -z "$WIDGET_APPEX" ]; then
    echo "${RED}WIDGET_MISSING: в PlugIns основного приложения нет .appex — Widget Extension не встроен!${RESET}"
else
    echo "${GREEN}Widget Extension: $(basename "$WIDGET_APPEX") (в PlugIns основного приложения)${RESET}"
fi
echo ""

# ---------- 4. Аудит отдельного bundle ----------

audit_bundle() {
    local BUNDLE="$1"
    local KIND="$2"   # "APP" | "APPEX"
    local SHORT=$(echo "$BUNDLE" | sed "s|$WORKDIR/unpacked/||")

    echo "${BOLD}──────── [$KIND] $SHORT ────────${RESET}"

    local INFO="$BUNDLE/Info.plist"
    if [ ! -f "$INFO" ]; then
        echo "${RED}  ! Info.plist отсутствует${RESET}"
        echo ""
        return
    fi

    # 4.1 Идентичность
    local BID=$(plist_get "$INFO" "CFBundleIdentifier")
    local DISPLAY=$(plist_get "$INFO" "CFBundleDisplayName")
    local GROUP_KEY=$(plist_get "$INFO" "AppGroupIdentifier")
    local VERSION=$(plist_get "$INFO" "CFBundleShortVersionString")
    local EXT_POINT=$(plist_get "$INFO" "NSExtension:NSExtensionPointIdentifier")
    echo "  Bundle ID:            ${BID:-<нет>}"
    echo "  Display Name:         ${DISPLAY:--}"
    echo "  Version:              ${VERSION:--}"
    [ -n "$EXT_POINT" ] && echo "  Extension Point:      $EXT_POINT"
    echo "  AppGroupIdentifier:   ${GROUP_KEY:-<нет>}"

    # 4.2 Подпись и entitlements
    # codesign -d --entitlements :- пишет XML plist в stdout (stderr — служебное).
    local ENT_PLIST="$WORKDIR/entitlements.plist"
    codesign -d --entitlements :- "$BUNDLE" > "$ENT_PLIST" 2>/dev/null

    if [ -s "$ENT_PLIST" ]; then
        echo "  Подпись:              ${GREEN}entitlements присутствуют${RESET}"

        local ENT_APPID=$(plist_get "$ENT_PLIST" "application-identifier")
        local ENT_TEAM=$(plist_get "$ENT_PLIST" "com.apple.developer.team-identifier")
        local ENT_APS=$(plist_get "$ENT_PLIST" "aps-environment")
        local ENT_GROUPS=$(groups_from_plist "$ENT_PLIST")

        echo "  application-id:       ${ENT_APPID:-<нет>}"
        echo "  team-identifier:      ${ENT_TEAM:-<нет>}"
        echo "  aps-environment:      ${ENT_APS:-<нет>}"
        if [ -n "$ENT_GROUPS" ]; then
            echo "  App Groups (подпись):"
            echo "$ENT_GROUPS" | sed 's/^/      • /'
        else
            echo "  App Groups (подпись): ${RED}ОТСУТСТВУЮТ — контейнер будет недоступен!${RESET}"
        fi

        # 4.2.1 Консистентность: группа в Info.plist есть в entitlements
        if [ -n "$GROUP_KEY" ] && [ -n "$ENT_GROUPS" ]; then
            if echo "$ENT_GROUPS" | grep -qxF "$GROUP_KEY"; then
                echo "  Консистентность:      ${GREEN}группа Info.plist есть в entitlements ($GROUP_KEY)${RESET}"
            else
                echo "  Консистентность:      ${RED}РАСХОЖДЕНИЕ: код запросит «$GROUP_KEY», подпись даёт другую группу!${RESET}"
            fi
        fi
    else
        echo "  Подпись:              ${YELLOW}entitlements не прочитаны (нет подписи)${RESET}"
    fi

    # 4.3 Верификация подписи
    if codesign --verify --strict "$BUNDLE" >/dev/null 2>&1; then
        echo "  codesign --verify:    ${GREEN}OK${RESET}"
    else
        echo "  codesign --verify:    ${YELLOW}не пройдена (допустимо для ad-hoc; после GBox — разбираться)${RESET}"
    fi

    # 4.4 Embedded provisioning profile
    local PROFILE="$BUNDLE/embedded.mobileprovision"
    if [ -f "$PROFILE" ]; then
        local PROF_PLIST="$WORKDIR/profile.plist"
        if security cms -D -i "$PROFILE" > "$PROF_PLIST" 2>/dev/null && [ -s "$PROF_PLIST" ]; then
            local P_NAME=$(plist_get "$PROF_PLIST" "Name")
            local P_APPID=$(plist_get "$PROF_PLIST" "Entitlements:application-identifier")
            local P_EXPIRY=$(plist_get "$PROF_PLIST" "ExpirationDate")
            local P_GROUPS=$(groups_from_plist "$PROF_PLIST")
            local P_DEV_COUNT
            P_DEV_COUNT=$(plutil -convert json -o - "$PROF_PLIST" 2>/dev/null \
                | grep -o '"[0-9A-F]\{25,\}"' | wc -l | tr -d ' ')

            echo "  Embedded profile:     ${P_NAME:--}"
            echo "    profile App ID:     ${P_APPID:-<нет>}"
            echo "    срок действия:      ${P_EXPIRY:--}"
            echo "    устройств:          ${P_DEV_COUNT:-0}"
            if [ -n "$P_GROUPS" ]; then
                echo "    разрешённые группы:"
                echo "$P_GROUPS" | sed 's/^/      • /'
                if [ -n "$GROUP_KEY" ]; then
                    if echo "$P_GROUPS" | grep -qxF "$GROUP_KEY"; then
                        echo "    Консистентность:    ${GREEN}запрашиваемая группа разрешена профилем${RESET}"
                    else
                        echo "    Консистентность:    ${RED}запрашиваемая группа НЕ входит в профиль!${RESET}"
                    fi
                fi
            else
                echo "    разрешённые группы: ${RED}профиль не содержит App Groups${RESET}"
            fi
        else
            echo "  Embedded profile:     ${YELLOW}не декодируется (security cms)${RESET}"
        fi
    else
        echo "  Embedded profile:     — (нет embedded.mobileprovision — норма для unsigned/ad-hoc CI-сборки)"
    fi

    # 4.5 Архитектура
    local EXEC_NAME=$(plist_get "$INFO" "CFBundleExecutable")
    if [ -n "$EXEC_NAME" ] && [ -f "$BUNDLE/$EXEC_NAME" ]; then
        echo "  Архитектура:          $(lipo -info "$BUNDLE/$EXEC_NAME" 2>/dev/null | sed 's/.*: //')"
    fi
    echo ""
}

# ---------- 5. Аудит всех bundle ----------

audit_bundle "$MAIN_APP" "APP"
find "$PAYLOAD" -name "*.appex" -type d | sort | while read -r APPEX; do
    audit_bundle "$APPEX" "APPEX"
done

# ---------- 6. Итог ----------

hr
label "ИТОГ"
echo "• Основное приложение: $( [ -d "$MAIN_APP" ] && echo "${GREEN}присутствует${RESET}" || echo "${RED}нет${RESET}" )"
echo "• Widget Extension:    $( [ -n "$WIDGET_APPEX" ] && echo "${GREEN}присутствует${RESET}" || echo "${RED}нет${RESET}" )"
echo ""
echo "Что сравнивать до/после GBox (см. docs/testing-checklist.md):"
echo "  1) App Groups в entitlements каждого bundle — сохранились ли после переподписи;"
echo "  2) application-identifier каждого bundle — какой App ID поставил GBox;"
echo "  3) embedded.mobileprovision — какой профиль встроен в main и в .appex;"
echo "  4) структура PlugIns — не удалил ли GBox расширение;"
echo "  5) codesign --verify --strict для каждого bundle."
echo ""
echo "Аудит завершён. Рабочие файлы удалены."
