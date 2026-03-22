#!/usr/bin/env bash
# linuwu-kb-enforce - Continuously enforce keyboard backlight settings
# Runs as a daemon, re-applying settings every second to combat EC resets
set -euo pipefail

SYSFS="/sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi"
KB_FX=""
KB_PZ=""

# Detect paths
for variant in nitro_sense predator_sense; do
    if [[ -d "$SYSFS/$variant" ]]; then
        KB_FX="$SYSFS/four_zoned_kb/four_zone_mode"
        KB_PZ="$SYSFS/four_zoned_kb/per_zone_mode"
        break
    fi
done

if [[ -z "$KB_FX" || ! -f "$KB_FX" ]]; then
    echo "Error: four_zoned_kb not found. Is linuwu_sense loaded?" >&2
    exit 1
fi

# Configuration: edit these to change what gets enforced
# Mode: "off", "static", or "per-zone"
MODE="off"
# For per-zone: hex colors per zone and brightness
PZ_COLORS="ffffff,ffffff,ffffff,ffffff"
PZ_BRIGHTNESS=10

# Load config if it exists
CONFIG="/etc/linuwu-kb.conf"
if [[ -f "$CONFIG" ]]; then
    source "$CONFIG"
fi

apply_settings() {
    case "$MODE" in
        off)
            echo "0,0,0,0,0,0,0" > "$KB_FX" 2>/dev/null || true
            ;;
        static)
            echo "0,0,$PZ_BRIGHTNESS,0,255,255,255" > "$KB_FX" 2>/dev/null || true
            echo "$PZ_COLORS,$PZ_BRIGHTNESS" > "$KB_PZ" 2>/dev/null || true
            ;;
        per-zone)
            echo "0,0,$PZ_BRIGHTNESS,0,255,255,255" > "$KB_FX" 2>/dev/null || true
            echo "$PZ_COLORS,$PZ_BRIGHTNESS" > "$KB_PZ" 2>/dev/null || true
            ;;
    esac
}

cleanup() {
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

echo "Keyboard enforcer started (mode=$MODE, brightness=$PZ_BRIGHTNESS)"

while true; do
    apply_settings
    sleep 1
done
