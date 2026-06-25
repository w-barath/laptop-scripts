#!/bin/bash
# Rate-Limited Laptop Charging Daemon
# (C) 2026 William Barath w.barath@gmail.com, MIT 3-clause license
#
# Purpose: operate laptop in one of 2 modes:
# slow - default - takes its sweet time to charge to 80% for battery health
# fast - toggle  - races to 95% when away from home etc.
# 
# I wrote this initially to avoid overheating an enclosed 65W car charger.

BATTERY_PATH="/sys/class/power_supply/BAT0"
COOL_DOWN_MINUTES=3
TARGET_MAX=83
TOPUP_MAX=95
DEFAULT_START=80
DEFAULT_MAX=85

# Auto-elevate to root
[ "$EUID" -ne 0 ] && exec sudo -- "$0" "$@"

IS_FAST=0
CEILING=$TARGET_MAX

if [ ! -d "$BATTERY_PATH" ]; then
    echo "$BATTERY_PATH not found.  Please configure $0 !";
    exit 1
fi

set_thresholds() {
    echo "$1" > "$BATTERY_PATH/charge_control_start_threshold"
    echo "$2" > "$BATTERY_PATH/charge_control_end_threshold"
}

stop_charging() {
    set_thresholds 0 "$(cat "$BATTERY_PATH/capacity")"
}

start_charging() {
    set_thresholds "$(( $(cat "$BATTERY_PATH/capacity") + 1 ))" "$TOPUP_MAX"
}

send_notification() {
    if [ -n "$SUDO_USER" ]; then
        local user_uid=$(id -u "$SUDO_USER")
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
            notify-send -i "${2:-battery}" "Battery Manager" "$1"
    fi
}

toggle_mode() {
    if (( IS_FAST ^= 1 )); then
        CEILING=$TOPUP_MAX
        send_notification "Travel Mode: Fast charging active" "battery-charging"
    else
        CEILING=$TARGET_MAX
        send_notification "Thermal Mode: Paced charging active" "battery-low"
    fi
}

cleanup() {
    echo -e "\nRestoring default thresholds..."
    set_thresholds "$DEFAULT_START" "$DEFAULT_MAX"
    send_notification "Daemon stopped. Limits restored."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP
trap toggle_mode SIGUSR1

while true; do
    CURRENT_CAP=$(cat "$BATTERY_PATH/capacity")
    echo "--- Status: ${CURRENT_CAP}% | Fast Mode: ${IS_FAST} | Target: ${CEILING}% ---"

    if [ "$CURRENT_CAP" -ge "$CEILING" ]; then
        echo "Target charge $CEILING% reached - not charging."
		stop_charging;
		sleep 5m; continue;
    fi

    NEXT_TARGET=$((CURRENT_CAP + 1))
    echo "Stepping to ${NEXT_TARGET}%..."
    start_charging

    while [ "$(cat "$BATTERY_PATH/capacity")" -lt "$NEXT_TARGET" ]; do
        sleep 5
    done

    if (( ! IS_FAST )); then
        echo "Step done.  Pausing..."
        stop_charging
        
		(( END_SECONDS = SECONDS + COOL_DOWN_MINUTES * 60 ))
        while (( ! ( IS_FAST || SECONDS > END_SECONDS) )); do sleep 5; done
    fi
done
