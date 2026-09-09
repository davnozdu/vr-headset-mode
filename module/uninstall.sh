#!/system/bin/sh
# Вызывается менеджером при удалении модуля.

# Дисплей обязательно вернуть: иначе очки останутся немым монитором,
# а способа включить его обратно у пользователя уже не будет.
for f in /sys/class/drm/*-DP-*/status; do
    [ -f "$f" ] && echo detect > "$f" 2>/dev/null
done

PIDFILE=/data/adb/vr_headset/daemon.pid
[ -f "$PIDFILE" ] && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
rm -f "$PIDFILE" /data/adb/bin/vr-mode

# Список устройств и лог оставляем: при переустановке настройки сохранятся.
