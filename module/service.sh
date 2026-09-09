#!/system/bin/sh
# late_start service: система загружена, settings и dumpsys отвечают.

MODDIR=${0%/*}
export MODDIR
. "$MODDIR/common.sh"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 5

log "=== модуль запущен (версия $(grep '^version=' "$MODDIR/module.prop" | cut -d= -f2)) ==="

mkdir -p "$CFGDIR"

# Приложение ставится до запуска демона: если установка затянется, режим
# всё равно применится вовремя.
sh "$MODDIR/install-app.sh"

# Список очков кладётся один раз и дальше правится пользователем: при
# обновлении модуля его затирать нельзя, иначе слетят добавленные устройства.
if [ ! -f "$DEVICES" ]; then
    cp "$MODDIR/devices.conf.default" "$DEVICES"
    log "создан список устройств: $DEVICES"
fi

# Режим по умолчанию задаём явно, чтобы vr-display-module, если он стоит,
# видел то же самое значение, а не догадывался.
[ -f "$MODEFILE" ] || echo headset > "$MODEFILE"
log "режим: $(current_mode)"

# vr-mode кладём в /data/adb/bin: /system только для чтения, а PATH туда
# всё равно не смотрит — зато путь предсказуемый и переживает обновления.
mkdir -p /data/adb/bin
cp "$MODDIR/vr-mode" /data/adb/bin/vr-mode 2>/dev/null
chmod 755 /data/adb/bin/vr-mode 2>/dev/null

nohup sh "$MODDIR/vrheadsetd.sh" >/dev/null 2>&1 &
sleep 2
if pgrep -f vrheadsetd.sh >/dev/null 2>&1; then
    log "демон запущен"
else
    log "ОШИБКА: демон не поднялся"
fi
