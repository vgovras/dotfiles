#!/usr/bin/env bash
# Перезапуск waybar з чистим середовищем (обхід LD_LIBRARY_PATH від Flatpak Zed)
killall -q waybar
while pgrep -x waybar >/dev/null; do sleep 0.2; done
nohup env -u LD_LIBRARY_PATH -u ZED_FLATPAK_LIB_PATH waybar >/tmp/waybar.log 2>&1 &
disown
