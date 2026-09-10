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

# Идентификаторы своих очков из devices.conf, по одному в строке.
#
# Берём первое слово строки, а не всю строку без пробелов: имя устройства
# может стоять и рядом с идентификатором — именно так его писал
# VR Companion, — а склеенное "3318:0436xrealonepro" не совпадало с
# vid:pid никогда, и режим гарнитуры молча умирал после первого же
# сохранения списка из приложения.
#
# Разбор идёт одним проходом sed, а не построчным циклом в шелле: раньше
# на каждую строку файла уходила четвёрка процессов echo/sed/tr/tr.
device_ids() {
    [ -f "$DEVICES" ] || return 0
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*//' -e '/^$/d' "$DEVICES" \
        | tr -d '\r' | tr 'A-Z' 'a-z'
}

# Пара vid:pid для USB-узла sysfs.
usb_id() {
    echo "$(cat "$1/idVendor" 2>/dev/null):$(cat "$1/idProduct" 2>/dev/null)"
}

# Очки на шине?
#
# Опознаём по USB, а не по DisplayPort: в режиме гарнитуры DP-коннектор мы
# сами гасим, и он рапортует disconnected — сенсор на его основе ослеп бы
# сразу после первого же срабатывания.
#
# Список читается один раз на вызов. Раньше файл перечитывался целиком для
# каждого узла шины: замер на OnePlus 15 дал 378 мс на вызов против 94 мс
# теперь, а вызов идёт раз в POLL_INTERVAL, то есть каждые две секунды.
glasses_present() {
    ids=$(device_ids)
    [ -n "$ids" ] || return 1
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        cur=$(usb_id "$d")
        for id in $ids; do
            [ "$id" = "$cur" ] && return 0
        done
    done
    return 1
}

# Имя найденных очков — только для лога.
glasses_name() {
    ids=$(device_ids)
    [ -n "$ids" ] || return 1
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        cur=$(usb_id "$d")
        for id in $ids; do
            if [ "$id" = "$cur" ]; then
                echo "$(cat "$d/product" 2>/dev/null || echo "$cur") ($cur)"
                return 0
            fi
        done
    done
    return 1
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
