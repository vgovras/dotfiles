#!/bin/sh
while true; do
    layout=$(swaymsg -t get_inputs | grep -m1 '"xkb_active_layout_name"' | sed 's/.*": "\(.*\)".*/\1/' | cut -c1-2 | tr '[:lower:]' '[:upper:]')
    profile=$(powerprofilesctl get)
    temp=$(awk '{printf "%.0f°C", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    echo "$temp | $profile | $layout | $(date +'%I:%M %p')"
    sleep 2
done
