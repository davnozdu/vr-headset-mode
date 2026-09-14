#!/system/bin/sh
# Вызывается установщиком модуля. Распаковщик не всегда сохраняет бит
# исполнения, а service.sh стартует раньше, чем это можно заметить.
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in "$MODPATH"/*.sh; do
    [ -f "$f" ] && set_perm "$f" 0 0 0755
done
set_perm "$MODPATH/vr-mode" 0 0 0755
set_perm "$MODPATH/vr-cam" 0 0 0755
set_perm "$MODPATH/vrcam" 0 0 0755
ui_print "- Скрипты модуля готовы"
ui_print "- После перезагрузки очки станут гарнитурой:"
ui_print "  телефон перестанет видеть их как монитор"
ui_print "- Переключение: vr-mode monitor / vr-mode headset"
