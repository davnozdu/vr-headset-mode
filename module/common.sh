#!/system/bin/sh
# Общее для скриптов модуля.

MODDIR=${MODDIR:-/data/adb/modules/vr_headset_mode}
CFGDIR=/data/adb/vr_headset
LOG=$CFGDIR/log
DEVICES=$CFGDIR/devices.conf
MODEFILE=/data/adb/vr_mode      # общий с VR Display Mode: monitor | headset
SETTINGS=$CFGDIR/settings.conf

# Настройки задержек. Файл необязателен: без него берутся значения по
# умолчанию, заданные ниже по месту использования.
[ -f "$SETTINGS" ] && . "$SETTINGS"

# Разделители полей для read, включая \r: devices.conf могли править
# в Windows. Считается один раз при подключении файла, не в цикле.
VR_IFS=$(printf ' \t\r')

log() {
    mkdir -p "$CFGDIR" 2>/dev/null
    # На раннем этапе загрузки date иногда возвращает пустоту, и запись
    # уходила в лог без отметки времени. Подстраховываемся аптаймом.
    TS=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -z "$TS" ] && TS="uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    echo "$TS $*" >> "$LOG"
    # Телефон работает месяцами без перезагрузки — лог не должен расти вечно.
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
        tail -c 131072 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

# Узлы DisplayPort. Имя коннектора зависит от платформы (на OnePlus 15 это
# card0-DP-1), поэтому берём все подходящие, а не один зашитый путь.
dp_nodes() {
    for f in /sys/class/drm/*-DP-*/status; do
        [ -f "$f" ] && echo "$f"
    done
}

# Текущий режим. По умолчанию headset: модуль ставят ради него.
current_mode() {
    m=$(cat "$MODEFILE" 2>/dev/null)
    case "$m" in
        monitor|headset) echo "$m" ;;
        *)               echo headset ;;
    esac
}

# Поиск своих очков на шине.
#
# Ни одного внешнего процесса: функция вызывается в цикле демона каждые
# POLL_INTERVAL секунд, и цена имеет значение. Файлы sysfs читаются
# встроенным read, а не $(cat ...); devices.conf разбирается подстановками
# параметров. Замер на OnePlus 15: 62 мс на вызов было, 1 мс стало.
#
# Опознаём по USB, а не по DisplayPort: в режиме гарнитуры картинку мы
# сами гасим, и сенсор на основе DP ослеп бы после первого срабатывания.
#
# Файл перечитывается на каждой проверке — так обещано в его шапке,
# правки подхватываются без перезапуска демона.
#
# Результат: GLASSES_ID и GLASSES_NAME.
find_glasses() {
    GLASSES_ID=""
    GLASSES_NAME=""
    [ -f "$DEVICES" ] || return 1
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        read -r vid < "$d/idVendor" 2>/dev/null || continue
        read -r pid < "$d/idProduct" 2>/dev/null || continue
        cur="$vid:$pid"
        # read с VR_IFS сам отрезает ведущие пробелы и \r, а лишние поля
        # уходят в rest — из строки "3318:0436 XREAL One Pro" остаётся
        # идентификатор. Раньше строка бралась целиком без пробелов, и
        # склеенное "3318:0436xrealonepro" не совпадало никогда.
        while IFS="$VR_IFS" read -r first rest || [ -n "$first" ]; do
            first=${first%%#*}
            [ -n "$first" ] || continue
            # Регистр приводим только когда есть что приводить: в файле от
            # приложения и в дефолтном он уже нижний, и форк не нужен.
            case "$first" in
                *[ABCDEF]*) first=$(echo "$first" | tr 'A-Z' 'a-z') ;;
            esac
            [ "$first" = "$cur" ] || continue
            GLASSES_ID=$cur
            [ -f "$d/product" ] && read -r GLASSES_NAME < "$d/product" 2>/dev/null
            [ -n "$GLASSES_NAME" ] || GLASSES_NAME=$cur
            return 0
        done < "$DEVICES"
    done
    return 1
}

# Очки на шине?
glasses_present() {
    find_glasses
}

# Имя найденных очков — только для лога.
glasses_name() {
    find_glasses || return 1
    echo "$GLASSES_NAME ($GLASSES_ID)"
}




# Утилита управления дисплеем из модуля VR Display Mode.
# Свою копию не держим: дублировать dex значило бы однажды разойтись
# версиями и получить два разных поведения.
DEX=/data/adb/modules/vr_display_mode/vrdisplay.dex

display_ctl() {
    [ -f "$DEX" ] || { echo "dex не найден"; return 1; }
    CLASSPATH="$DEX" app_process /system/bin com.davnozdu.vrdisplay.DisplayCtl "$1" 2>&1
}

# Звуковая карта очков поднялась?
audio_ready() {
    grep -q 'USB-Audio' /proc/asound/cards 2>/dev/null
}

# Внешний дисплей виден системе?
display_present() {
    [ "$(dumpsys display 2>/dev/null | grep -c 'DisplayViewport{type=EXTERNAL')" -gt 0 ]
}

# Погасить картинку в очках.
#
# Через IDisplayManager.disableConnectedDisplay, а не гашением DRM-коннектора:
# принудительный disconnected очки считают извлечением кабеля и сбрасываются
# целиком вместе со звуковой картой — проверено замером, отваливались каждые
# 10-15 секунд. Здесь коннектор остаётся подключённым, USB и звук не страдают,
# а очки, не получая кадров, гасят панели сами.
hide_display() {
    out=$(display_ctl disable)
    case "$out" in
        *"disabled display"*) log "дисплей выключен: $out"; return 0 ;;
        *)                    log "не удалось выключить дисплей: $out"; return 1 ;;
    esac
}

# Без записи в журнал: вызываются в цикле и при пробуждении.
hide_quiet() {
    display_ctl disable >/dev/null 2>&1
    dismiss_quiet
}

# Закрыть диалог молча: в цикле журнал засорять нечем.
dismiss_quiet() {
    case "$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)" in
        *systemui*) input keyevent 4 ;;
    esac
}

show_quiet() {
    display_ctl enable >/dev/null 2>&1
}

# Вернуть картинку.
show_display() {
    out=$(display_ctl enable)
    case "$out" in
        *"enabled display"*) log "дисплей включён: $out"; return 0 ;;
        *)                   log "не удалось включить дисплей: $out"; return 1 ;;
    esac
}

# Снять принудительное состояние DRM-коннектора.
#
# Нужно на старте: от прежних версий модуля на коннекторе мог остаться
# форсированный off, и тогда линк не поднимается вовсе — очки видны по USB,
# звуковая карта есть, а дисплея нет и включать нечего.
clear_force() {
    for f in $(dp_nodes); do
        echo detect > "$f" 2>/dev/null
    done
}

# Разбудить очки.
#
# Включение дисплея — программный эквивалент кнопки "каст" в системном
# диалоге. Именно оно поднимает аудиоусилитель очков: при отмене диалога
# звука не появляется вовсе.
#
# Ждать появления звуковой карты бесполезно: она регистрируется при
# перечислении USB, независимо от того, включён усилитель или нет.
# Поэтому просто выдерживаем паузу после включения.
wait_ready() {
    show_quiet
    sleep "${READY_GRACE:-6}"
    display_present
}

dp_state() {
    for f in $(dp_nodes); do
        echo "$(basename "$(dirname "$f")")=$(cat "$f" 2>/dev/null)"
    done
}
