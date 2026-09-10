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

# Снимаем возможный остаток форсированного состояния от прежних версий:
# с ним линк не поднимется и включать будет нечего.
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
            ready=no
        fi
    fi
    [ "$mode" != "$prev_mode" ] && [ -n "$prev_mode" ] && log "режим переключён: $mode"

    if [ "$present" = yes ] && [ "$mode" = headset ]; then
        if [ "$ready" = no ]; then
            # Гасить до появления звуковой карты нельзя: аудиоусилитель очков
            # включается после успешного линка, и преждевременное выключение
            # оставляло систему с гарнитурой, которой она отдаёт звук, а из
            # динамиков ничего не идёт.
            if wait_ready; then
                if hide_display; then
                    dismiss_quiet
                    log "картинка выключена, звук остался"
                    ready=yes
                fi
            fi
        else
            # Дисплей возвращается сам после выхода телефона из сна, так что
            # гасить приходится повторно. Но сначала дешёвая проверка:
            # display_present — это dumpsys, 21 мс, а hide_quiet поднимает
            # виртуальную машину через app_process, 495 мс (замер на
            # OnePlus 15). Раньше эти полсекунды тратились каждые две
            # секунды всё время, пока очки на голове.
            display_present && hide_quiet
        fi
    fi

    prev_present=$present
    prev_mode=$mode
    sleep "$POLL_INTERVAL"
done
