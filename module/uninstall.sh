#!/system/bin/sh
# Вызывается менеджером при удалении модуля.

# Дисплей обязательно вернуть: иначе очки останутся немым монитором,
# а способа включить его обратно у пользователя уже не будет.
for f in /sys/class/drm/*-DP-*/status; do
    [ -f "$f" ] || continue
    echo detect > "$f" 2>/dev/null
done
sleep 1
# detect после принудительного off находит пустоту: линк уже разорван.
# Форсируем on, иначе пользователь останется без дисплея и без модуля,
# которым его можно было бы вернуть.
for f in /sys/class/drm/*-DP-*/status; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "connected" ] || echo on > "$f" 2>/dev/null
done

PIDFILE=/data/adb/vr_headset/daemon.pid
[ -f "$PIDFILE" ] && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
rm -f "$PIDFILE" /data/adb/bin/vr-mode

# Список устройств и лог оставляем: при переустановке настройки сохранятся.
