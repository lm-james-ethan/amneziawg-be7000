#!/bin/sh
# AmneziaWG Toggle Script with Watchdog - Xiaomi Edition

# --- Configuration ---
AWG_DIR="/data/usr/app/awg"
CFG="$AWG_DIR/amnezia_for_awg.conf"
IFCFG="/tmp/awg0_runtime.conf"
TOOLS_BIN="$AWG_DIR/awg"
AWG_GO="$AWG_DIR/amneziawg-go"
WATCHDOG_SCRIPT="$AWG_DIR/awg_watchdog.sh"
LAN_BR="br-lan"
STATE_FILE="/tmp/awg_wan_state"

die() { echo "Error: $*" >&2; exit 1; }
root() { [ "$(id -u)" -eq 0 ] || die "Run as root"; }

# --- Cron / Watchdog Management ---
manage_cron() {
    ACTION=$1
    # Check if watchdog exists before adding
    [ ! -f "$WATCHDOG_SCRIPT" ] && return
    
    CRON_CMD="* * * * * sh $WATCHDOG_SCRIPT > /dev/null 2>&1"
    
    # Filter out existing watchdog entries to prevent duplicates
    CURRENT_CRON=$(crontab -l 2>/dev/null | grep -vF "$WATCHDOG_SCRIPT")
    
    if [ "$ACTION" = "add" ]; then
        (echo "$CURRENT_CRON"; echo "$CRON_CMD") | crontab -
        echo "Watchdog enabled."
    elif [ "$ACTION" = "del" ]; then
        echo "$CURRENT_CRON" | crontab -
        echo "Watchdog disabled."
    fi
}

# --- Helper Functions ---
save_wan_info() {
    ROUTE_INFO=$(ip route show default | head -n 1)
    GW=$(echo "$ROUTE_INFO" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    IF=$(echo "$ROUTE_INFO" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

    if [ -n "$GW" ] && [ -n "$IF" ] && [ "$IF" != "awg0" ]; then
        echo "$GW $IF" > "$STATE_FILE"
        return 0
    fi
    return 1
}

get_saved_wan() {
    [ -f "$STATE_FILE" ] && read -r WAN_GW WAN_IF < "$STATE_FILE"
}

# --- Main Commands ---
up() {
root
root
    if [ -d "/sys/class/net/awg0" ]; then
        echo "VPN is already up. Restarting for you..."
        down
        sleep 1
    fi

 



    echo "Starting AmneziaWG..."
    WG_SERVER=$(grep "^Endpoint" "$CFG" | sed 's/.*= *//' | cut -d':' -f1 | tr -d '\r ')
    WG_ADDR=$(grep "^Address" "$CFG" | sed 's/.*= *//' | cut -d',' -f1 | tr -d '\r ')
    grep -vE "^Address|^DNS" "$CFG" > "$IFCFG"

    save_wan_info || echo "Warning: Using existing WAN state"
    get_saved_wan
    [ -z "$WAN_GW" ] && die "Could not detect WAN Gateway."

    # Start AmneziaWG-go
    export WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1
    "$AWG_GO" awg0 > /tmp/awg_log 2>&1 &
    
    # Wait for interface (Busybox compatible loop)
    COUNT=0
    while [ ! -d "/sys/class/net/awg0" ]; do
        sleep 1
        COUNT=$((COUNT + 1))
        [ $COUNT -ge 10 ] && die "Interface timeout. Check /tmp/awg_log"
    done

    sleep 1 # Handshake delay
    "$TOOLS_BIN" setconf awg0 "$IFCFG" || die "Config failed."
    
    ip addr add "$WG_ADDR" dev awg0
    ip link set mtu 1280 dev awg0
    ip link set up awg0

    # Routing
    ip route add "$WG_SERVER"/32 via "$WAN_GW" dev "$WAN_IF"
    ip route del default
    ip route add default dev awg0
    
    # Firewall
    iptables -I FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT
    iptables -t nat -I POSTROUTING -o awg0 -j MASQUERADE
    
    manage_cron add
    echo "VPN IS UP."
}

down() {
    root
    echo "Stopping VPN..."
    manage_cron del
    get_saved_wan
    
    WG_SERVER=$(grep "^Endpoint" "$CFG" | sed 's/.*= *//' | cut -d':' -f1 | tr -d '\r ')

    ip route del default dev awg0 2>/dev/null
    [ -n "$WG_SERVER" ] && ip route del "$WG_SERVER"/32 2>/dev/null
    [ -n "$WAN_GW" ] && ip route add default via "$WAN_GW" dev "$WAN_IF" 2>/dev/null

    ip link del awg0 2>/dev/null
    killall amneziawg-go 2>/dev/null
    
    iptables -D FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null
    
    rm -f "$STATE_FILE" "$IFCFG"
    echo "VPN IS DOWN."
}

status() {
    if [ -d "/sys/class/net/awg0" ]; then
        echo "[CONNECTED]"
        "$TOOLS_BIN" show awg0
    else
        echo "[DISCONNECTED]"
    fi
}

case "$1" in
    up|down|status) "$1" ;;
    restart) down; sleep 2; up ;;
    *) echo "Usage: $0 {up|down|status|restart}" ;;
esac
