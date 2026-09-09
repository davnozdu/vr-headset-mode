#!/system/bin/sh
# Общее для скриптов модуля.

MODDIR=${MODDIR:-/data/adb/modules/vr_headset_mode}
CFGDIR=/data/adb/vr_headset
LOG=$CFGDIR/log
DEVICES=$CFGDIR/devices.conf
MODEFILE=/data/adb/vr_mode      # общий с VR Display Mode: monitor | headset

log() {
    mkdir -p "$CFGDIR" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
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
show_display() {
    for f in $(dp_nodes); do
        echo detect > "$f" 2>/dev/null
    done
}

dp_state() {
    for f in $(dp_nodes); do
        echo "$(basename "$(dirname "$f")")=$(cat "$f" 2>/dev/null)"
    done
}
