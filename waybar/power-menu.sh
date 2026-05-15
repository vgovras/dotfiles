#!/usr/bin/env bash
# Power menu via rofi — reuses the sway-wide theme.
options="󰌾  Lock\n󰍃  Logout\n󰤄  Suspend\n󰜉  Reboot\n󰐥  Shutdown"

choice=$(echo -e "$options" | rofi -dmenu -i -p "Power" \
    -theme ~/.config/rofi/themes/squared-nord.rasi \
    -theme-str 'window {width: 250px;}')

case "$choice" in
    *Lock)      swaylock -f -c 1e1e2e --indicator-idle-visible --indicator-radius 100 --show-failed-attempts ;;
    *Logout)    swaymsg exit ;;
    *Suspend)   systemctl suspend ;;
    *Reboot)    systemctl reboot ;;
    *Shutdown)  systemctl poweroff ;;
esac
