#!/system/bin/sh
# Следит за очками и держит их в режиме гарнитуры.

MODDIR=${MODDIR:-${0%/*}}
case "$MODDIR" in ""|.|"$0") MODDIR=/data/adb/modules/vr_headset_mode;; esac
. "$MODDIR/common.sh"

POLL_INTERVAL=2

# Один демон на систему. pkill по имени здесь ненадёжен: под SELinux он
# срабатывает не всегда, а после ручных перезапусков экземпляры копились бы.
PIDFILE=$CFGDIR/daemon.pid
mkdir -p "$CFGDIR"
if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && [ -d "/proc/$OLD" ]; then
        kill -9 "$OLD" 2>/dev/null && log "остановлен прежний демон ($OLD)"
    fi
fi
echo $$ > "$PIDFILE"

log "демон: старт"
prev_present=""
prev_mode=""

while true; do
    mode=$(current_mode)
    if glasses_present; then present=yes; else present=no; fi

    # Сообщаем только об изменениях: иначе лог за сутки станет нечитаемым.
    if [ "$present" != "$prev_present" ]; then
        if [ "$present" = yes ]; then
            log "очки подключены: $(glasses_name)"
        else
            log "очки отключены"
        fi
    fi
    [ "$mode" != "$prev_mode" ] && [ -n "$prev_mode" ] && log "режим переключён: $mode"

    if [ "$present" = yes ] && [ "$mode" = headset ]; then
        # Применяем на каждой итерации, а не только на изменении: коннектор
        # возвращается в connected сам после переподключения кабеля, выхода
        # из сна и перезапуска дисплейной подсистемы.
        for f in $(dp_nodes); do
            if [ "$(cat "$f" 2>/dev/null)" = "connected" ]; then
                echo off > "$f" 2>/dev/null
                log "дисплей скрыт ($(basename "$(dirname "$f")"))"
            fi
        done
    fi

    prev_present=$present
    prev_mode=$mode
    sleep "$POLL_INTERVAL"
done
