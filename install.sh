#!/bin/sh
# QWERTY manual beta installation. This file is intended to be readable before use.
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

MANIFEST_URL=https://raw.githubusercontent.com/fedorenkodenis/qwerty-beta/main/terminal-install.json
ARCHIVE_URL=https://github.com/fedorenkodenis/qwerty-beta/releases/download/terminal-beta/QWERTY.zip
BUNDLE_ID=coffee.qwerty.switcher

working=
stage=
lock=
lock_gate=
lock_helper=
lock_token=
installer_uid=
destination=
previous=
log=
step=starting
moved=0
installed=0
stopped=0
success=0

note() { printf '%s\n' "$*"; }
record() {
    if [ -n "$log" ]; then
        printf '%s %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" 2>/dev/null >> "$log" || true
    fi
}
fail() { record "failure=$step"; note "$*" >&2; note "Этап установки: $step" >&2; exit 1; }

# AppKit process inspection does not request Accessibility or Apple Events access.
# All operations refer to the exact application URL as well as its bundle ID.
process() {
    /usr/bin/osascript -l JavaScript - "$1" "$destination" "$BUNDLE_ID" <<'JXA'
ObjC.import('AppKit');
function run(args) {
    const action = args[0], path = args[1], bundle = args[2];
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundle);
    const matches = [];
    let other = false;
    for (let index = 0; index < apps.count; index++) {
        const app = apps.objectAtIndex(index);
        const location = app.bundleURL;
        if (!location || !location.path) continue;
        if (ObjC.unwrap(location.path) === path) matches.push(app);
        else other = true;
    }
    if (action === 'other') return other ? 'yes' : 'no';
    if (action === 'terminate') {
        for (const app of matches) if (!app.terminate) throw Error('termination-refused');
        return 'requested';
    }
    if (matches.length > 1) throw Error('multiple-target-processes');
    return matches.length ? String(matches[0].processIdentifier) : '0';
}
JXA
}

stop_target() {
    process terminate >> "$log" 2>&1 || return 1
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(process pid 2>> "$log") || return 1
        [ "$pid" = 0 ] && return 0
        /bin/sleep 1
    done
    return 1
}

prepare_lock_helper() {
    lock_helper="$working/lock-helper.sh"
    /bin/cat > "$lock_helper" <<'LOCK_HELPER'
#!/bin/sh
set -eu
umask 077
action=$1
path=$2
request_pid=$3
request_uid=$4
request_token=$5

read_field() { /bin/cat "$path/$1" 2>/dev/null || true; }
owned_directory() {
    [ -d "$path" ] && [ ! -L "$path" ] &&
        [ "$(/usr/bin/stat -f %u "$path")" = "$request_uid" ]
}
retire_directory() {
    # Every installer holds the same kernel lease while moving this directory.
    # A subsequent owner can only create a new lock after this section returns.
    retired=$(/usr/bin/mktemp -d "${path}.abandoned-XXXXXXXX")
    if ! /bin/mv "$path" "$retired/lock"; then /bin/rmdir "$retired"; return 1; fi
    /bin/rm -rf "$retired"
}

if [ "$action" = release ]; then
    if owned_directory && [ "$(read_field pid)" = "$request_pid" ] &&
        [ "$(read_field uid)" = "$request_uid" ] && [ "$(read_field token)" = "$request_token" ]; then
        retire_directory
    fi
    exit 0
fi

for attempt in 1 2 3 4 5 6; do
    if /bin/mkdir "$path" 2>/dev/null; then
        printf '%s\n' "$request_pid" > "$path/pid"
        printf '%s\n' "$request_uid" > "$path/uid"
        printf '%s\n' "$request_token" > "$path/token"
        exit 0
    fi
    owned_directory || exit 75
    old_uid=$(read_field uid)
    old_pid=$(read_field pid)
    old_token=$(read_field token)
    [ -z "$old_uid" ] || [ "$old_uid" = "$request_uid" ] || exit 75
    case "$old_pid" in
        ''|*[!0-9]*) complete=0;;
        *)
            [ "$old_pid" -gt 1 ] || exit 75
            # A live process always retains its lock. Refuse ambiguous PID reuse.
            if /bin/kill -0 "$old_pid" 2>/dev/null; then exit 75; fi
            if [ -n "$(/bin/ps -p "$old_pid" -o pid= 2>/dev/null || true)" ]; then exit 75; fi
            complete=1
            ;;
    esac
    if [ "$complete" -eq 0 ]; then
        age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f %m "$path") ))
        if [ "$age" -lt 3 ]; then /bin/sleep 1; continue; fi
    fi
    # Re-check captured ownership immediately before moving the old directory.
    owned_directory && [ "$(read_field uid)" = "$old_uid" ] &&
        [ "$(read_field pid)" = "$old_pid" ] && [ "$(read_field token)" = "$old_token" ] || exit 75
    retire_directory
done
exit 75
LOCK_HELPER
}

lock_action() {
    /usr/bin/lockf -k -t 8 "$lock_gate" /bin/sh "$lock_helper" \
        "$1" "$lock" "$$" "$installer_uid" "$lock_token"
}

cleanup() {
    exit_code=$?
    set +e
    trap - EXIT HUP INT TERM
    if [ -n "$log" ] && ! { [ -f "$log" ] && printf '%s\n' 'cleanup=started' >> "$log"; } 2>/dev/null; then
        note 'Не удалось дописать диагностику установки. Проверяю возврат прежней версии.' >&2
        log=/dev/null
    fi
    if [ "$success" -eq 0 ]; then
        record "rollback=begin status=$exit_code"
        can_restore=1
        if [ "$installed" -eq 1 ]; then
            if [ "$(read_value CFBundleIdentifier "$destination/Contents/Info.plist" 2>/dev/null || true)" != "$BUNDLE_ID" ] ||
                [ "$(read_value CFBundleVersion "$destination/Contents/Info.plist" 2>/dev/null || true)" != "$build" ]; then
                can_restore=0
                record 'rollback=destination-changed'
            elif stop_target; then
                /bin/rm -rf "$destination"
            else
                can_restore=0
                note 'Новая QWERTY не завершилась. Закрой её и повтори установку.' >&2
                record 'rollback=target-still-running'
            fi
        fi
        if [ "$moved" -eq 1 ] && [ "$can_restore" -eq 1 ]; then
            if [ ! -e "$destination" ] && /bin/mv "$previous" "$destination"; then
                record 'rollback=previous-restored'
            else
                can_restore=0
                record 'rollback=restore-failed'
            fi
        fi
        if [ "$stopped" -eq 1 ] && [ "$can_restore" -eq 1 ] && [ -d "$destination" ]; then
            /usr/bin/open -g "$destination" >> "$log" 2>&1 || true
        fi
        if [ "$can_restore" -eq 0 ] && [ -d "$previous" ]; then
            note "Прежняя версия сохранена в $previous" >&2
            stage=
        fi
        if [ -n "$log" ] && [ "$log" != /dev/null ]; then note "Диагностика установки сохранена в $log" >&2; fi
    fi
    if [ -n "$lock" ] && [ -n "$lock_helper" ] && [ -f "$lock_helper" ]; then
        lock_action release >> "$log" 2>&1 || record 'lock=release-deferred'
    fi
    [ -z "$working" ] || /bin/rm -rf "$working"
    [ -z "$stage" ] || /bin/rm -rf "$stage"
    exit "$exit_code"
}

read_value() { /usr/bin/plutil -extract "$1" raw -o - "$2" 2>> "$log"; }

check_existing() {
    [ ! -L "$destination" ] || fail 'Установленная QWERTY является ссылкой. Установка остановлена.'
    [ -e "$destination" ] || return 0
    [ -d "$destination" ] || fail 'Путь для QWERTY занят другим файлом.'
    current_bundle=$(read_value CFBundleIdentifier "$destination/Contents/Info.plist") || fail 'Не удалось прочитать установленную QWERTY.'
    [ "$current_bundle" = "$BUNDLE_ID" ] || fail 'В папке находится другое приложение с названием QWERTY.'
    current_build=$(read_value CFBundleVersion "$destination/Contents/Info.plist") || fail 'Не удалось определить установленную сборку.'
    case "$current_build" in ''|*[!0-9]*) fail 'Номер установленной сборки не распознан.';; esac
    [ "$current_build" -le "$build" ] || fail 'На этом Mac уже установлена более новая QWERTY. Понижение версии остановлено.'
}

main() {
    [ "$(/usr/bin/uname -s)" = Darwin ] || fail 'Этот установщик предназначен для macOS.'
    [ -n "${HOME:-}" ] && [ -d "$HOME" ] || fail 'Не удалось определить домашнюю папку пользователя.'
    case "$HOME" in /*) ;; *) fail 'У домашней папки должен быть абсолютный путь.';; esac
    [ "$(/usr/bin/id -u)" -ne 0 ] || fail 'Запусти команду от своего имени, без sudo.'
    version_os=$(/usr/bin/sw_vers -productVersion)
    major_os=${version_os%%.*}
    case "$major_os" in ''|*[!0-9]*) fail 'Не удалось определить версию macOS.';; esac
    [ "$major_os" -ge 26 ] || fail 'Этой бета-версии QWERTY нужна macOS 26 или новее.'
    architecture=$(/usr/bin/uname -m)
    case "$architecture" in arm64|x86_64) ;; *) fail 'Эта архитектура Mac пока не поддерживается.';; esac

    log_folder="$HOME/Library/Logs/QWERTY"
    /bin/mkdir -p "$log_folder"
    log=$(/usr/bin/mktemp "$log_folder/install-$(/bin/date -u +%Y%m%d-%H%M%S)-XXXXXX")
    working=$(/usr/bin/mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    record "system=$version_os architecture=$architecture"

    applications=/Applications
    if [ ! -e /Applications/QWERTY.app ] && { [ -e "$HOME/Applications/QWERTY.app" ] || [ ! -w /Applications ]; }; then
        applications="$HOME/Applications"
        [ ! -L "$applications" ] || fail 'Папка «Программы» пользователя является ссылкой. Выбери обычную папку для установки.'
        /bin/mkdir -p "$applications"
    fi
    [ -d "$applications" ] && [ ! -L "$applications" ] && [ -w "$applications" ] ||
        fail 'Установленную общую QWERTY может обновить только владелец папки «Программы».'
    destination="$applications/QWERTY.app"
    [ ! -L "$destination" ] || fail 'Установленная QWERTY является ссылкой. Установка остановлена.'

    step=lock
    lock="$applications/.qwerty-terminal-install.lock"
    lock_gate="$applications/.qwerty-terminal-install.reclaim"
    installer_uid=$(/usr/bin/id -u)
    lock_token=$(/usr/bin/uuidgen)
    [ ! -L "$lock_gate" ] && [ ! -d "$lock_gate" ] || fail 'Файл блокировки установки имеет неожиданный формат.'
    if [ -e "$lock_gate" ]; then
        [ "$(/usr/bin/stat -f %u "$lock_gate")" = "$installer_uid" ] || fail 'Эту установку уже подготовил другой пользователь Mac.'
    fi
    prepare_lock_helper
    if ! lock_action acquire >> "$log" 2>&1; then
        fail 'Другая установка QWERTY уже запущена. Дождись её завершения.'
    fi

    step=manifest
    note 'Скачиваю QWERTY и проверяю сборку…'
    /usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        --connect-timeout 15 --max-time 60 --max-filesize 65536 \
        "$MANIFEST_URL" -o "$working/manifest.json" >> "$log" 2>&1 || fail 'Не удалось получить описание сборки. Проверь подключение и повтори команду.'
    manifest="$working/manifest.json"
    release=$(read_value version "$manifest") || fail 'В описании сборки отсутствует версия.'
    build=$(read_value build "$manifest") || fail 'В описании сборки отсутствует номер сборки.'
    url=$(read_value archive_url "$manifest") || fail 'В описании сборки отсутствует ссылка.'
    bytes=$(read_value archive_bytes "$manifest") || fail 'В описании сборки отсутствует размер.'
    checksum=$(read_value archive_sha256 "$manifest") || fail 'В описании сборки отсутствует контрольная сумма.'
    bundle=$(read_value bundle_id "$manifest") || fail 'В описании сборки отсутствует идентификатор.'
    minimum=$(read_value minimum_system_version "$manifest") || fail 'В описании сборки отсутствует версия macOS.'
    architecture_arm=$(read_value architectures.0 "$manifest") || fail 'В описании сборки отсутствует архитектура Apple Silicon.'
    architecture_intel=$(read_value architectures.1 "$manifest") || fail 'В описании сборки отсутствует архитектура Intel.'
    printf '%s\n' "$release" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'Некорректная версия сборки.'
    case "$build:$bytes" in *[!0-9:]*) fail 'Некорректный размер или номер сборки.';; esac
    [ "$build" -gt 0 ] && [ "$bytes" -gt 0 ] && [ "$bytes" -le 67108864 ] || fail 'Некорректный размер или номер сборки.'
    [ "$bundle" = "$BUNDLE_ID" ] && [ "$url" = "$ARCHIVE_URL" ] || fail 'Описание ссылается на другое приложение или сервер.'
    [ "$minimum" = 26.0 ] && [ "$architecture_arm" = arm64 ] && [ "$architecture_intel" = x86_64 ] ||
        fail 'Описание сборки не соответствует этой версии установщика.'
    [ "${#checksum}" -eq 64 ] || fail 'Некорректная контрольная сумма.'
    case "$checksum" in *[!0-9a-f]*) fail 'Некорректная контрольная сумма.';; esac
    record "release=$release build=$build"

    check_existing
    other=$(process other 2>> "$log") || fail 'Не удалось проверить запущенные копии QWERTY.'
    [ "$other" = no ] || fail 'QWERTY запущена из другой папки. Закрой её и повтори команду.'

    step=download
    /usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
        --connect-timeout 15 --max-time 180 --max-filesize "$bytes" \
        "$url" -o "$working/QWERTY.zip" >> "$log" 2>&1 || fail 'Архив не скачался полностью. Прежняя программа сохранена. Повтори команду.'
    [ "$(/usr/bin/stat -f %z "$working/QWERTY.zip")" -eq "$bytes" ] || fail 'Размер архива не совпал. Установка остановлена.'
    actual=$(/usr/bin/shasum -a 256 "$working/QWERTY.zip" | /usr/bin/awk '{print $1}')
    [ "$actual" = "$checksum" ] || fail 'Архив не прошёл проверку целостности. Установка остановлена.'

    step=archive
    /usr/bin/zipinfo -1 "$working/QWERTY.zip" > "$working/paths" 2>> "$log" || fail 'Не удалось прочитать архив.'
    /usr/bin/awk '
        BEGIN {bad=0}
        /^\// || /\\/ || /(^|\/)\.\.(\/|$)/ || /[[:cntrl:]]/ {bad=1}
        !/^QWERTY\.app\// && !/^__MACOSX\// {bad=1}
        END {exit bad || NR == 0 || NR > 20000}
    ' "$working/paths" || fail 'В архиве обнаружены недопустимые пути.'
    /usr/bin/zipinfo -l "$working/QWERTY.zip" > "$working/entries" 2>> "$log" || fail 'Не удалось проверить состав архива.'
    /usr/bin/awk '/^[-dl]/ {total += $4} END {exit total > 268435456}' "$working/entries" || fail 'Распакованный архив слишком велик.'
    /usr/bin/sed -n 's/^l[^ ]* *[^ ]* *[^ ]* *[^ ]* *[^ ]* *[^ ]* *[^ ]* *[^ ]* *[^ ]* *//p' "$working/entries" > "$working/links"
    while IFS= read -r path; do
        target=$(/usr/bin/unzip -p "$working/QWERTY.zip" "$path") || fail 'Не удалось проверить ссылку в архиве.'
        case "$target" in ''|/*|*\\*) fail 'Недопустимая ссылка в архиве.';; esac
        printf '%s\n' "$target" | /usr/bin/awk '/(^|\/)\.\.(\/|$)/ || /[[:cntrl:]]/ {exit 1}' || fail 'Ссылка выходит за пределы приложения.'
    done < "$working/links"
    /usr/bin/ditto -x -k "$working/QWERTY.zip" "$working/unpacked" >> "$log" 2>&1 || fail 'Не удалось распаковать QWERTY.'
    candidate="$working/unpacked/QWERTY.app"
    [ -d "$candidate" ] && [ ! -L "$candidate" ] || fail 'В архиве отсутствует QWERTY.'
    info="$candidate/Contents/Info.plist"
    [ "$(read_value CFBundleIdentifier "$info")" = "$BUNDLE_ID" ] &&
        [ "$(read_value CFBundleShortVersionString "$info")" = "$release" ] &&
        [ "$(read_value CFBundleVersion "$info")" = "$build" ] &&
        [ "$(read_value LSMinimumSystemVersion "$info")" = "$minimum" ] || fail 'Приложение не совпадает с описанием сборки.'
    [ -x "$candidate/Contents/MacOS/QWERTY" ] || fail 'Главный файл QWERTY не имеет права запуска.'
    /usr/bin/file -b "$candidate/Contents/MacOS/QWERTY" | /usr/bin/grep -q "$architecture" || fail 'Сборка не подходит для процессора этого Mac.'
    /usr/bin/codesign --verify --deep --strict --all-architectures "$candidate" >> "$log" 2>&1 || fail 'Подпись QWERTY не прошла проверку.'

    step=staging
    stage=$(/usr/bin/mktemp -d "$applications/.qwerty-install-XXXXXXXX")
    staged="$stage/QWERTY.app"
    previous="$stage/previous.app"
    /usr/bin/ditto "$candidate" "$staged" >> "$log" 2>&1 || fail 'Не удалось подготовить приложение в папке «Программы».'
    /usr/bin/codesign --verify --deep --strict --all-architectures "$staged" >> "$log" 2>&1 || fail 'Копия приложения не прошла проверку.'

    step=replace
    check_existing
    other=$(process other 2>> "$log") || fail 'Не удалось перепроверить запущенные копии QWERTY.'
    [ "$other" = no ] || fail 'Во время загрузки QWERTY запустилась из другой папки. Закрой её и повтори команду.'
    pid=$(process pid 2>> "$log") || fail 'Не удалось проверить работающую QWERTY.'
    if [ "$pid" != 0 ]; then
        note 'Обновляю QWERTY. Настройки и исключения сохранятся.'
        stopped=1
        stop_target || fail 'QWERTY не завершилась. Закрой её и повтори команду.'
    fi
    if [ -e "$destination" ]; then
        /bin/mv "$destination" "$previous" || fail 'Не удалось сохранить прежнюю копию.'
        moved=1
    fi
    /bin/mv "$staged" "$destination" || fail 'Не удалось перенести QWERTY в «Программы».'
    installed=1

    step=launch
    # This manual-beta route changes quarantine only on the installed QWERTY bundle.
    /usr/bin/xattr -dr com.apple.quarantine "$destination" >> "$log" 2>&1 || true
    launched_at=$(/bin/date +%s)
    /usr/bin/open -g -n "$destination" >> "$log" 2>&1 || fail 'macOS отклонила запуск QWERTY. Прежняя версия будет восстановлена.'
    health="$HOME/Library/Application Support/QWERTY/engine-health.json"
    stable=0
    previous_pid=0
    ready=0
    for attempt in $(/usr/bin/seq 1 30); do
        pid=$(process pid 2>> "$log") || fail 'Не удалось подтвердить процесс QWERTY.'
        if [ "$pid" != 0 ] && [ "$pid" = "$previous_pid" ]; then stable=$((stable + 1)); else stable=0; fi
        previous_pid=$pid
        if [ "$stable" -ge 5 ] && [ -f "$health" ] &&
            [ "$(/usr/bin/stat -f %m "$health")" -ge "$launched_at" ] &&
            [ "$(read_value pid "$health" 2>/dev/null || true)" = "$pid" ] &&
            [ "$(read_value version "$health" 2>/dev/null || true)" = "$release" ] &&
            [ "$(read_value build "$health" 2>/dev/null || true)" = "$build" ]; then
            ready=1
            break
        fi
        /bin/sleep 1
    done
    [ "$ready" -eq 1 ] || fail 'QWERTY не подтвердила запуск. Прежняя версия будет восстановлена.'
    success=1
    record "result=launched build=$build"
    note 'QWERTY установлена и запустилась.'
    if [ "$(read_value inputMonitoring "$health" 2>/dev/null || true)" != true ] ||
        [ "$(read_value accessibility "$health" 2>/dev/null || true)" != true ]; then
        note 'В приветственном окне включи доступ к клавиатуре и универсальный доступ. Эти разрешения подтверждаются в настройках macOS.'
    fi
    note "Диагностика установки сохранена в $log"
}

main "$@"
