#!/bin/sh

# IP to ping to check for a live connection.
CHECK_IP="1.1.1.1"
SETUP_SCRIPT="/data/usr/app/awg/awg_start.sh"

# Check if the awg0 interface exists. If not, the connection is definitely down.
if ! ip link show awg0 > /dev/null 2>&1; then
    logger -t awg_watchdog "Interface awg0 not found. Restarting connection."
    $SETUP_SCRIPT up
    exit 0
fi

# Ping the check IP through the awg0 interface.
# -c 1: Send only 1 packet.
# -W 3: Wait a maximum of 3 seconds for a reply.
ping -c 3 -W 3 -I awg0 $CHECK_IP > /dev/null 2>&1

# Check the exit code of the ping command. 0 means success.
if [ $? -ne 0 ]; then
    logger -t awg_watchdog "Ping check failed. Restarting connection."
    # The connection is down, run the main setup script to fix it.
    $SETUP_SCRIPT restart
fi
