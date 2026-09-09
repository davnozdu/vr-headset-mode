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

# Ждём, пока очки полностью проснутся.
#
# Их аудиоусилитель включается только после успешного DisplayPort-линка.
# Если погасить коннектор раньше, система видит гарнитуру и отдаёт ей
# звук, а из динамиков ничего не идёт — проверено на живом устройстве.
#
# Поэтому дожидаемся и линка, и появления звуковой карты, а сверх того
# выдерживаем паузу: карта регистрируется раньше, чем усилитель выходит
# на режим.
wait_ready() {
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
    # Не дождались: гасить нельзя, иначе останемся без звука. Пусть лучше
    # дисплей повисит — это заметно и поправимо, а немая гарнитура нет.
    log "очки не проснулись за ${W}с — дисплей не трогаю"
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
# Сначала detect — он возвращает штатное автоопределение. Но после
# принудительного off физический линк разорван, и переопрос ничего не
# находит: коннектор так и остаётся disconnected. Тогда форсируем on —
# ядро проводит модсет заново, и дисплей оживает.
show_display() {
    for f in $(dp_nodes); do
        echo detect > "$f" 2>/dev/null
    done
    sleep 1
    for f in $(dp_nodes); do
        [ "$(cat "$f" 2>/dev/null)" = "connected" ] || echo on > "$f" 2>/dev/null
    done
}

dp_state() {
    for f in $(dp_nodes); do
        echo "$(basename "$(dirname "$f")")=$(cat "$f" 2>/dev/null)"
    done
}
