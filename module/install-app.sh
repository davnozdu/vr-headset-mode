#!/system/bin/sh
# Ставит или обновляет VR Companion из состава модуля.

MODDIR=${MODDIR:-${0%/*}}
case "$MODDIR" in ""|.|"$0") MODDIR=/data/adb/modules/vr_headset_mode;; esac
. "$MODDIR/common.sh"

PKG=com.davnozdu.vrcompanion
APK="$MODDIR/vr-companion.apk"

[ -f "$APK" ] || { log "APK в модуле нет — пропускаю установку"; exit 0; }

WANT=$(cat "$MODDIR/apk-versioncode" 2>/dev/null || echo 0)
HAVE=$(dumpsys package "$PKG" 2>/dev/null | grep -m1 versionCode= | sed 's/.*versionCode=\([0-9]*\).*/\1/')
[ -z "$HAVE" ] && HAVE=0

if [ "$HAVE" -ge "$WANT" ] 2>/dev/null; then
    log "VR Companion уже версии $HAVE (в модуле $WANT) — установка не нужна"
    exit 0
fi

log "устанавливаю VR Companion: было $HAVE, ставлю $WANT"
OUT=$(pm install -r -g "$APK" 2>&1)
case "$OUT" in
    *Success*)
        log "VR Companion установлен"
        ;;
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*signatures*)
        # Подписи расходятся, если приложение ставили вручную из другого
        # источника. Молча удалять чужую сборку нельзя — с ней уйдут
        # настройки, поэтому только сообщаем.
        log "ОШИБКА: подпись установленного VR Companion не совпадает с модулем."
        log "Удалите приложение вручную и перезагрузитесь — модуль поставит своё."
        ;;
    *)
        log "не удалось установить VR Companion: $OUT"
        ;;
esac
