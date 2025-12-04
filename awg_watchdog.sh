#!/bin/sh

# Configuration
CHECK_IP="1.1.1.1"
# Points to the main switch script
SWITCH_SCRIPT="/data/usr/app/awg/awg_route_switch.sh"

# 1. Check if we intend to be online
# If the state file doesn't exist, the user probably ran 'down', so we shouldn't intervene.
if [ ! -f "/tmp/awg_wan_info" ]; then
    exit 0
fi

# 2. Check Interface existence
if ! ip link show awg0 > /dev/null 2>&1; then
    logger -t awg_watchdog "Interface awg0 missing. Restarting..."
    sh "$SWITCH_SCRIPT" down
    sh "$SWITCH_SCRIPT" up
    exit 0
fi

# 3. Check Connectivity (Ping)
# -c 1: One packet
# -W 5: Wait 5 seconds
if ! ping -c 1 -W 5 -I awg0 "$CHECK_IP" > /dev/null 2>&1; then
    logger -t awg_watchdog "Ping check to $CHECK_IP failed. Restarting VPN..."
    sh "$SWITCH_SCRIPT" down
    sh "$SWITCH_SCRIPT" up
fi
