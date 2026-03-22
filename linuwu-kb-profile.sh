#!/usr/bin/env bash
# linuwu-kb-profile - Quick keyboard backlight profile switcher
# Updates /etc/linuwu-kb.conf so the enforcer daemon persists the setting
set -euo pipefail

CONFIG="/etc/linuwu-kb.conf"

write_config() {
    local mode="$1" colors="$2" brightness="$3"
    cat > "$CONFIG" <<EOF
MODE="$mode"
PZ_COLORS="$colors"
PZ_BRIGHTNESS=$brightness
EOF
}

profile="${1:-dim-white}"

case "$profile" in
    off)
        write_config "off" "ffffff,ffffff,ffffff,ffffff" 0
        echo "Keyboard backlight: OFF"
        ;;
    dim-white)
        write_config "per-zone" "ffffff,ffffff,ffffff,ffffff" 10
        echo "Keyboard backlight: dim white (10%)"
        ;;
    white)
        write_config "per-zone" "ffffff,ffffff,ffffff,ffffff" 50
        echo "Keyboard backlight: white (50%)"
        ;;
    bright-white)
        write_config "per-zone" "ffffff,ffffff,ffffff,ffffff" 100
        echo "Keyboard backlight: bright white (100%)"
        ;;
    red)
        write_config "per-zone" "ff0000,ff0000,ff0000,ff0000" 50
        echo "Keyboard backlight: red (50%)"
        ;;
    blue)
        write_config "per-zone" "0000ff,0000ff,0000ff,0000ff" 50
        echo "Keyboard backlight: blue (50%)"
        ;;
    custom)
        shift
        if [[ $# -lt 1 ]]; then
            echo "Usage: $0 custom RRGGBB,RRGGBB,RRGGBB,RRGGBB,BRIGHTNESS" >&2
            exit 1
        fi
        local brightness
        brightness=$(echo "$1" | awk -F, '{print $5}')
        local colors
        colors=$(echo "$1" | awk -F, '{print $1","$2","$3","$4}')
        [[ -z "$brightness" ]] && brightness=50
        write_config "per-zone" "$colors" "$brightness"
        echo "Keyboard backlight: custom ($1)"
        ;;
    *)
        echo "Unknown profile: $profile"
        echo "Available: off, dim-white, white, bright-white, red, blue, custom"
        exit 1
        ;;
esac
