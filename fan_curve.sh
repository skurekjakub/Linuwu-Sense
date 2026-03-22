#!/usr/bin/env bash
# fan_curve.sh - Temperature-based fan curve daemon for Linuwu-Sense
# Reads CPU/GPU temps from hwmon, maps to fan speed %, writes to sysfs
set -euo pipefail

# --- Configuration ---
# Poll interval in seconds
POLL_INTERVAL=3

# hwmon sensor paths (auto-detected below, override if needed)
CPU_TEMP_PATH=""
GPU_TEMP_PATH=""

# sysfs fan control (auto-detected below)
FAN_SPEED_PATH=""

# Fan curve: "temp_celsius:fan_percent" pairs (ascending order)
# Fan speed is linearly interpolated between points.
# CPU curve
CPU_CURVE=(
    "40:0"    # 40°C and below → auto (0 = auto mode)
    "55:30"   # 55°C → 30%
    "65:45"   # 65°C → 45%
    "75:60"   # 75°C → 60%
    "85:80"   # 85°C → 80%
    "90:100"  # 90°C+ → 100%
)

# GPU curve
GPU_CURVE=(
    "40:0"    # 40°C and below → auto
    "55:30"
    "65:45"
    "75:60"
    "85:80"
    "90:100"
)

# Hysteresis in °C - prevents rapid fan speed changes
HYSTERESIS=3

# --- End Configuration ---

last_cpu_speed=-1
last_gpu_speed=-1
last_cpu_temp=0
last_gpu_temp=0

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Find hwmon path by name
find_hwmon() {
    local name="$1"
    for hwmon in /sys/class/hwmon/hwmon*; do
        if [[ -f "$hwmon/name" ]] && [[ "$(cat "$hwmon/name")" == "$name" ]]; then
            echo "$hwmon"
            return 0
        fi
    done
    return 1
}

# Auto-detect sensor paths
detect_paths() {
    if [[ -z "$CPU_TEMP_PATH" ]]; then
        local cpu_hwmon
        cpu_hwmon=$(find_hwmon "k10temp") || cpu_hwmon=$(find_hwmon "coretemp") || cpu_hwmon=$(find_hwmon "acpitz") || true
        if [[ -n "$cpu_hwmon" ]]; then
            CPU_TEMP_PATH="$cpu_hwmon/temp1_input"
        else
            die "Cannot find CPU temperature sensor (tried k10temp, coretemp, acpitz)"
        fi
    fi

    if [[ -z "$GPU_TEMP_PATH" ]]; then
        local gpu_hwmon
        gpu_hwmon=$(find_hwmon "amdgpu") || gpu_hwmon=$(find_hwmon "nvidia") || true
        if [[ -n "$gpu_hwmon" ]]; then
            GPU_TEMP_PATH="$gpu_hwmon/temp1_input"
        else
            log "WARN: No GPU temperature sensor found, GPU fan will follow CPU"
        fi
    fi

    if [[ -z "$FAN_SPEED_PATH" ]]; then
        # Try nitro_sense first, then predator_sense
        for variant in nitro_sense predator_sense; do
            local p="/sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi/$variant/fan_speed"
            if [[ -f "$p" ]]; then
                FAN_SPEED_PATH="$p"
                break
            fi
        done
        [[ -n "$FAN_SPEED_PATH" ]] || die "Cannot find fan_speed sysfs path. Is linuwu_sense loaded?"
    fi

    log "CPU temp: $CPU_TEMP_PATH"
    log "GPU temp: ${GPU_TEMP_PATH:-<none, following CPU>}"
    log "Fan ctrl: $FAN_SPEED_PATH"
}

# Read temperature in °C (hwmon reports millidegrees)
read_temp() {
    local path="$1"
    local raw
    raw=$(cat "$path" 2>/dev/null) || return 1
    echo $(( raw / 1000 ))
}

# Interpolate fan speed from a curve array given a temperature
# Uses linear interpolation between defined points
interpolate() {
    local temp=$1
    shift
    local curve=("$@")

    local prev_temp prev_speed
    IFS=: read -r prev_temp prev_speed <<< "${curve[0]}"

    # Below the lowest point
    if (( temp <= prev_temp )); then
        echo "$prev_speed"
        return
    fi

    for point in "${curve[@]:1}"; do
        local cur_temp cur_speed
        IFS=: read -r cur_temp cur_speed <<< "$point"

        if (( temp <= cur_temp )); then
            # Linear interpolation
            local range=$(( cur_temp - prev_temp ))
            local speed_range=$(( cur_speed - prev_speed ))
            local offset=$(( temp - prev_temp ))
            echo $(( prev_speed + (offset * speed_range) / range ))
            return
        fi

        prev_temp=$cur_temp
        prev_speed=$cur_speed
    done

    # Above the highest point
    echo "$prev_speed"
}

# Apply hysteresis: only update if temp moved enough
apply_hysteresis() {
    local current_temp=$1
    local last_temp=$2
    local new_speed=$3
    local last_speed=$4

    # If speed would increase, apply immediately
    if (( new_speed > last_speed )); then
        echo "$new_speed"
        return
    fi

    # If speed would decrease, only do so if temp dropped by HYSTERESIS
    if (( (last_temp - current_temp) >= HYSTERESIS )); then
        echo "$new_speed"
    else
        echo "$last_speed"
    fi
}

set_fan_speed() {
    local cpu_pct=$1
    local gpu_pct=$2

    if (( cpu_pct == last_cpu_speed && gpu_pct == last_gpu_speed )); then
        return 0
    fi

    echo "$cpu_pct,$gpu_pct" > "$FAN_SPEED_PATH" 2>/dev/null || {
        log "WARN: Failed to write fan speed (permission denied?)"
        return 1
    }

    log "Fan → CPU:${cpu_pct}% GPU:${gpu_pct}% (temps: CPU:${last_cpu_temp}°C GPU:${last_gpu_temp}°C)"
    last_cpu_speed=$cpu_pct
    last_gpu_speed=$gpu_pct
}

cleanup() {
    log "Shutting down, setting fans to auto..."
    echo "0,0" > "$FAN_SPEED_PATH" 2>/dev/null || true
    exit 0
}

main() {
    log "Linuwu-Sense fan curve daemon starting"
    detect_paths

    trap cleanup SIGTERM SIGINT SIGHUP

    log "Fan curve active (poll every ${POLL_INTERVAL}s, hysteresis ${HYSTERESIS}°C)"
    log "CPU curve: ${CPU_CURVE[*]}"
    log "GPU curve: ${GPU_CURVE[*]}"
    echo ""

    while true; do
        local cpu_temp gpu_temp
        cpu_temp=$(read_temp "$CPU_TEMP_PATH") || { sleep "$POLL_INTERVAL"; continue; }

        if [[ -n "$GPU_TEMP_PATH" ]]; then
            gpu_temp=$(read_temp "$GPU_TEMP_PATH") || gpu_temp=$cpu_temp
        else
            gpu_temp=$cpu_temp
        fi

        local cpu_speed gpu_speed
        # Use the higher of CPU/GPU temp for both fans so they spin equally
        local max_temp=$(( cpu_temp > gpu_temp ? cpu_temp : gpu_temp ))
        cpu_speed=$(interpolate "$max_temp" "${CPU_CURVE[@]}")
        gpu_speed=$cpu_speed

        cpu_speed=$(apply_hysteresis "$max_temp" "$last_cpu_temp" "$cpu_speed" "$last_cpu_speed")
        gpu_speed=$(apply_hysteresis "$max_temp" "$last_gpu_temp" "$gpu_speed" "$last_gpu_speed")

        last_cpu_temp=$cpu_temp
        last_gpu_temp=$gpu_temp

        set_fan_speed "$cpu_speed" "$gpu_speed"

        sleep "$POLL_INTERVAL"
    done
}

main "$@"
