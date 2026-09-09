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

# Очки на шине?
#
# Опознаём по USB, а не по DisplayPort: в режиме гарнитуры DP-коннектор мы
# сами гасим, и он рапортует disconnected — сенсор на его основе ослеп бы
# сразу после первого же срабатывания.
glasses_present() {
    [ -f "$DEVICES" ] || return 1
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        vid=$(cat "$d/idVendor" 2>/dev/null)
        pid=$(cat "$d/idProduct" 2>/dev/null)
        # Пустые строки и комментарии пропускаем, регистр не важен.
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | tr -d ' \t\r' | tr 'A-Z' 'a-z')
            [ -z "$line" ] && continue
            [ "$line" = "$vid:$pid" ] && return 0
        done < "$DEVICES"
    done
    return 1
}

# Имя найденных очков — только для лога.
glasses_name() {
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        vid=$(cat "$d/idVendor" 2>/dev/null)
        pid=$(cat "$d/idProduct" 2>/dev/null)
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | tr -d ' \t\r' | tr 'A-Z' 'a-z')
            [ -z "$line" ] && continue
            if [ "$line" = "$vid:$pid" ]; then
                echo "$(cat "$d/product" 2>/dev/null || echo "$vid:$pid") ($vid:$pid)"
                return 0
            fi
        done < "$DEVICES"
    done
}



# Снять принудительное состояние коннектора: вернуть автоопределение.
#
# Нужно при отключении очков. Иначе форсированное состояние переживает
# извлечение кабеля: остаётся либо фантомный дисплей (если было on), либо
# погашенный линк, с которого следующее подключение уже не поднимется.
clear_force() {
    for f in $(dp_nodes); do
        echo detect > "$f" 2>/dev/null
    done
}

# Принудительно поднять линк.
#
# Только on реально поднимает коннектор: detect переопрашивает физическое
# подключение и после форсированного off находит пустоту — проверено
# замером, коннектор так и остаётся disconnected.
force_on() {
    for f in $(dp_nodes); do
        echo on > "$f" 2>/dev/null
    done
}

# Звуковая карта очков поднялась?
audio_ready() {
    grep -q 'USB-Audio' /proc/asound/cards 2>/dev/null
}

# Хотя бы один DP-коннектор отрапортовал connected?
dp_up() {
    for f in $(dp_nodes); do
        [ "$(cat "$f" 2>/dev/null)" = "connected" ] && return 0
    done
    return 1
}

# Разбудить очки и дождаться готовности.
#
# Их аудиоусилитель включается только после успешного DisplayPort-линка.
# Погасить коннектор раньше — значит получить худший исход: система видит
# гарнитуру и отдаёт ей звук, DSP поднимает offload-поток, а ядро отвечает
# "invalid substream", и звук уходит в пустоту.
#
# Поэтому линк поднимается принудительно, затем ждём звуковую карту и
# выдерживаем паузу: карта регистрируется раньше, чем усилитель выходит
# на режим.
wait_ready() {
    force_on
    W=${READY_TIMEOUT:-20}
    i=0
    while [ $i -lt "$W" ]; do
        if dp_up && audio_ready; then
            sleep "${READY_GRACE:-5}"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    # Не дождались — гасить нельзя, иначе останемся без звука. Возвращаем
    # автоопределение: видимый монитор заметен и поправим, немая гарнитура нет.
    log "очки не проснулись за ${W}с — оставляю дисплей включённым"
    clear_force
    return 1
}

# Спрятать очки как монитор. Звук, микрофоны и камера при этом остаются:
# они живут на USB 2.0, независимо от DisplayPort.
hide_display() {
    done_any=1
    for f in $(dp_nodes); do
        if [ "$(cat "$f" 2>/dev/null)" != "disconnected" ]; then
            echo off > "$f" 2>/dev/null && done_any=0
        else
            done_any=0
        fi
    done
    return $done_any
}

# Вернуть монитор.
#
# Именно force_on, а не detect: после форсированного off переопрос находит
# пустоту, потому что линк уже разорван. Проверено замером.
show_display() {
    force_on
}

dp_state() {
    for f in $(dp_nodes); do
        echo "$(basename "$(dirname "$f")")=$(cat "$f" 2>/dev/null)"
    done
}
