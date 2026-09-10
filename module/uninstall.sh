#!/system/bin/sh
# Вызывается менеджером при удалении модуля.

# Картинку обязательно вернуть: иначе очки останутся немым монитором,
# а способа включить его обратно у пользователя уже не будет. Правильный
# обратный ход для disableConnectedDisplay — enable той же утилитой,
# а не запись в DRM-коннектор.
DEX=/data/adb/modules/vr_display_mode/vrdisplay.dex
[ -f "$DEX" ] && CLASSPATH="$DEX" app_process /system/bin \
    com.davnozdu.vrdisplay.DisplayCtl enable >/dev/null 2>&1

# Коннектор возвращаем к автоопределению. Форсировать 'on' здесь нельзя:
# принудительное состояние переживает извлечение кабеля и отравляет
# следующее подключение — коннектор рапортует connected всегда, смены
# состояния больше не бывает, и модуль VR Display Mode перестаёт включать
# дисплей вовсе. Форсированный 'off' этот модуль не ставит с v2.0 (гашение
# идёт через IDisplayManager), так что снимать нечего — detect достаточно.
# Если картинка всё же не вернулась, её поднимет перетык очков.
for f in /sys/class/drm/*-DP-*/status; do
    [ -f "$f" ] || continue
    echo detect > "$f" 2>/dev/null
done

PIDFILE=/data/adb/vr_headset/daemon.pid
[ -f "$PIDFILE" ] && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
rm -f "$PIDFILE" /data/adb/bin/vr-mode

# Список устройств и лог оставляем: при переустановке настройки сохранятся.
