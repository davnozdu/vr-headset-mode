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

# На старте состояние коннектора неизвестно: демон могли перезапустить
# поверх прежней сессии. Начинаем с чистого листа.
clear_force

log "демон: старт"
prev_present=""
prev_mode=""
ready=no          # очки этой сессии уже проснулись и их можно гасить

while true; do
    mode=$(current_mode)
    if glasses_present; then present=yes; else present=no; fi

    # Сообщаем только об изменениях: иначе лог за сутки станет нечитаемым.
    if [ "$present" != "$prev_present" ]; then
        if [ "$present" = yes ]; then
            log "очки подключены: $(glasses_name)"
        else
            log "очки отключены"
            # Снимаем принудительное состояние сразу. Иначе оно переживёт
            # отключение, и следующее подключение начнётся с погашенного
            # линка: очки не проснутся, звука не будет. Заодно исчезает
            # фантомный дисплей, если коннектор оставался форсирован в on.
            clear_force
            ready=no
        fi
    fi
    [ "$mode" != "$prev_mode" ] && [ -n "$prev_mode" ] && log "режим переключён: $mode"

    if [ "$present" = yes ] && [ "$mode" = headset ]; then
        if [ "$ready" = no ]; then
            # Очкам нужен хотя бы один успешный DisplayPort-линк, чтобы
            # включить свой аудиоусилитель. Если погасить коннектор раньше,
            # система видит гарнитуру и отдаёт ей звук, а из динамиков
            # ничего не идёт. Поэтому ждём готовности, а не гасим сразу.
            if wait_ready; then
                log "очки проснулись (линк и звук на месте), скрываю дисплей"
                hide_display
                ready=yes
            fi
        else
            # Коннектор возвращается в connected сам: после выхода из сна
            # и перезапуска дисплейной подсистемы. Возвращаем своё.
            for f in $(dp_nodes); do
                if [ "$(cat "$f" 2>/dev/null)" = "connected" ]; then
                    echo off > "$f" 2>/dev/null
                    log "дисплей скрыт повторно ($(basename "$(dirname "$f")"))"
                fi
            done
        fi
    fi

    prev_present=$present
    prev_mode=$mode
    sleep "$POLL_INTERVAL"
done
