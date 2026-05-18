#!/usr/bin/env bash
# Live-search Flatpak apps via rofi. Type to filter, Enter to install.

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE="$CACHE_DIR/flatpak-search.list"
CACHE_TTL=$((60 * 60 * 24)) # 1 day
TERM_CMD="${TERMINAL:-foot}"

mkdir -p "$CACHE_DIR"

needs_refresh() {
    [[ "$1" == "--refresh" ]] && return 0
    [[ ! -s "$CACHE" ]] && return 0
    local age=$(( $(date +%s) - $(stat -c %Y "$CACHE") ))
    (( age > CACHE_TTL ))
}

build_cache() {
    notify-send -t 2000 "Flatpak" "Refreshing app list..." 2>/dev/null
    flatpak remote-ls --app --columns=application,name,description 2>/dev/null \
        | awk -F'\t' 'NF>=2 {
            name = ($2 == "") ? $1 : $2
            desc = ($3 == "") ? "" : " — " $3
            printf "%s\t%s%s\n", $1, name, desc
          }' > "$CACHE"
}

if needs_refresh "$1"; then
    build_cache
fi

if [[ ! -s "$CACHE" ]]; then
    rofi -e "No flatpak apps found. Configure a remote, e.g.:\nflatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
    exit 1
fi

# Show only the display column to rofi; rofi filters live as you type.
selected=$(cut -f2 "$CACHE" | rofi -dmenu -i -p "Flatpak" -l 15 \
    -kb-custom-1 "Ctrl+r" -mesg "Ctrl+R: refresh cache")
rc=$?

# Ctrl+R pressed → rebuild cache and relaunch
if [[ $rc -eq 10 ]]; then
    build_cache
    exec "$0"
fi

[[ -z "$selected" ]] && exit 0

# Map display line back to app id (first column of the cache).
app_id=$(awk -F'\t' -v sel="$selected" '$2 == sel { print $1; exit }' "$CACHE")

if [[ -z "$app_id" ]]; then
    rofi -e "Could not resolve app ID for: $selected"
    exit 1
fi

$TERM_CMD sh -c "
    echo 'Installing $app_id ...'
    flatpak install -y '$app_id'
    status=\$?
    echo
    if [ \$status -eq 0 ]; then
        echo '✓ Done. Press Enter to close.'
    else
        echo '✗ Install failed (exit '\$status'). Press Enter to close.'
    fi
    read _
" &
