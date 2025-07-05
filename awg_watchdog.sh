#!/bin/sh
#
# awg_watchdog.sh  –  Re-connect awg0 automatically
#
# • Checks IPv4 reachability through awg0
# • On failure it:
#     1) ip link set down awg0
#     2) flushes addresses
#     3) runs the AmneziaWG helper binaries to re-load awg0.conf
#     4) re-adds the client address
#     5) brings the interface back up
# • Logs to syslog with tag “awg_watchdog”
# • Intended for a cron entry:  * * * * * /root/awg_watchdog.sh
#
##############################################################################
AWG_DIR="/data/usr/app/awg"
CFG="$AWG_DIR/amnezia_for_awg.conf"
IFCFG="$AWG_DIR/awg0.conf"
AWG_BIN="$AWG_DIR/awg"
AWG_GO="$AWG_DIR/amneziawg-go"

# Targets to test THROUGH the tunnel
TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
PING_WAIT=2        # seconds
TRIES=3            # how many different IPs must fail

##############################################################################
# Parse static values from original config
##############################################################################
WG_ADDR=$(awk -F' = ' '/^Address/ {print $2}' "$CFG")

##############################################################################
# Ping-check awg0
##############################################################################
fail=0
for ip in $TARGETS; do
    if ping -I awg0 -c 1 -W $PING_WAIT "$ip" >/dev/null 2>&1; then
        logger -t awg_watchdog "awg0 OK (ping $ip)"
        exit 0
    else
        fail=$((fail+1))
    fi
    [ $fail -ge $TRIES ] && break
done

##############################################################################
# If here, all pings failed ? restart awg0
##############################################################################
logger -t awg_watchdog "awg0 FAIL ($fail/${#TARGETS}) – restarting..."

# 1. Bring interface down and flush
ip link set awg0 down 2>/dev/null
ip addr flush dev awg0

# 2. Re-load config
"$AWG_GO" awg0 >/dev/null 2>&1
"$AWG_BIN" setconf awg0 "$IFCFG"

# 3. Re-add client address and bring link up
ip addr add "$WG_ADDR" dev awg0
ip link set up awg0

logger -t awg_watchdog "awg0 restarted"
exit 0
