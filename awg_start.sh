#!/bin/sh
# AmneziaWG Toggle Script - Dynamic Config Version

# --- Configuration ---
AWG_DIR="/data/usr/app/awg"
CFG="$AWG_DIR/amnezia_for_awg.conf"
IFCFG="$AWG_DIR/awg0.conf"
TOOLS_BIN="$AWG_DIR/awg"
AWG_GO="$AWG_DIR/amneziawg-go"
WATCHDOG_SCRIPT="$AWG_DIR/awg_watchdog.sh"
LAN_NET="192.168.31.0/24"
LAN_BR="br-lan"
STATE_FILE="/tmp/awg_wan_state"

die()   { echo "Error: $*" >&2; exit 1; }
root()  { [ "$(id -u)" -eq 0 ] || die "Run as root"; }

# --- Helper: Detect and Save WAN Gateway ---
save_wan_info() {
    ROUTE_INFO=$(ip route get 1.1.1.1 2>/dev/null | head -n 1)
    GW=$(echo "$ROUTE_INFO" | awk '{ for(i=1; i<=NF; i++) if ($i=="via") print $(i+1) }')
    IF=$(echo "$ROUTE_INFO" | awk '{ for(i=1; i<=NF; i++) if ($i=="dev") print $(i+1) }')

    if [ "$IF" = "awg0" ]; then
        echo "Detected awg0 as WAN. VPN is likely already up. Skipping save."
        return 1
    fi

    if [ -n "$GW" ] && [ -n "$IF" ]; then
        echo "$GW $IF" > "$STATE_FILE"
        echo "Saved WAN State: Gateway $GW on $IF"
        return 0
    else
        echo "Failed to detect WAN gateway!"
        return 1
    fi
}

get_saved_wan() {
    if [ -f "$STATE_FILE" ]; then
        WAN_GW=$(awk '{print $1}' "$STATE_FILE")
        WAN_IF=$(awk '{print $2}' "$STATE_FILE")
    else
        return 1
    fi
}

apply_fw() {
    iptables -C FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT
    iptables -C FORWARD -i awg0 -o "$LAN_BR" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o "$LAN_BR" -j ACCEPT
    iptables -C INPUT -i awg0 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg0 -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$LAN_NET" -o awg0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$LAN_NET" -o awg0 -j MASQUERADE
}

remove_fw() {
    iptables -D FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i awg0 -o "$LAN_BR" -j ACCEPT 2>/dev/null
    iptables -D INPUT -i awg0 -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -s "$LAN_NET" -o awg0 -j MASQUERADE 2>/dev/null
}

cron_add() {
    [ ! -f "$WATCHDOG_SCRIPT" ] && return
    CRON_CMD="* * * * * sh $WATCHDOG_SCRIPT > /dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    fi
}

cron_del() {
    if crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
        crontab -l 2>/dev/null | grep -vF "awg_watchdog.sh" | crontab -
    fi
}

up() {
    root
    if ip link show awg0 >/dev/null 2>&1; then
        echo "VPN is already UP."
        status
        exit 0
    fi

    echo "Starting VPN..."

    # --- Config Parsing ---
    WG_SERVER=$(grep "^Endpoint" "$CFG" | sed 's/.*= *//' | cut -d':' -f1 | tr -d '\r')
    
    # User Logic: Extract Address and Clean Config
    WG_ADDR=$(awk -F' = ' '/^Address/ {print $2}' "$CFG" | cut -d',' -f1 | tr -d '\r')
    awk '!/^Address/ && !/^DNS/' "$CFG" > "$IFCFG"
    
    [ -z "$WG_SERVER" ] || [ -z "$WG_ADDR" ] && die "Invalid config"

    save_wan_info || die "Could not detect WAN Gateway. Aborting."
    get_saved_wan 

    echo "Target Server: $WG_SERVER"
    echo "Routing via: $WAN_GW ($WAN_IF)"

    pkill -f amneziawg-go 2>/dev/null
    [ -d /dev/net ] || mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
    
    export WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1
    $AWG_GO awg0 >/dev/null 2>&1 &
    
    count=0
    while ! ip link show awg0 >/dev/null 2>&1; do
        sleep 0.5
        count=$((count+1))
        [ $count -ge 10 ] && die "awg0 failed to create interface."
    done

    ip addr flush dev awg0 2>/dev/null
    ip addr add "$WG_ADDR" dev awg0
    "$TOOLS_BIN" setconf awg0 "$IFCFG"
    ip link set up awg0
    ip link set mtu 1280 dev awg0

    ip route add "$WG_SERVER"/32 via "$WAN_GW" dev "$WAN_IF"
    ip route del default 2>/dev/null
    ip route add default dev awg0

    remove_fw
    apply_fw
    ip route flush cache
    cron_add
    /etc/init.d/firewall reload

    echo "VPN IS UP"
    echo -n "Public IP: "
    curl -s --max-time 5 ifconfig.me || echo "Check manually"
    echo
}

down() {
    echo "Stopping VPN..."
    root
    get_saved_wan 
    WG_SERVER=$(grep "^Endpoint" "$CFG" | sed 's/.*= *//' | cut -d':' -f1 | tr -d '\r')

    ip route del default dev awg0 2>/dev/null
    [ -n "$WG_SERVER" ] && ip route del "$WG_SERVER"/32 2>/dev/null
    
    if [ -n "$WAN_GW" ]; then
        echo "Restoring default route to $WAN_GW..."
        ip route del default 2>/dev/null
        ip route add default via "$WAN_GW" dev "$WAN_IF" 2>/dev/null
    else
        echo "Warning: No saved gateway. Restoring network..."
        /etc/init.d/network restart
    fi

    remove_fw
    [ -x "$(command -v conntrack)" ] && conntrack -F >/dev/null 2>&1
    
    ip link del awg0 2>/dev/null
    pkill -f amneziawg-go 2>/dev/null
    rm -f "$STATE_FILE" "$IFCFG" 2>/dev/null
    cron_del
    /etc/init.d/firewall reload

    echo "VPN IS DOWN"
}

status() {
    if ip link show awg0 >/dev/null 2>&1; then
        echo "VPN Status: [CONNECTED]"
        echo "Interface: awg0"
        echo "Uplink: $(ip route show default | grep awg0)"
    else
        echo "VPN Status: [DISCONNECTED]"
    fi
}

case "$1" in
    up) up ;;
    down) down ;;
    status) status ;;
    restart) down; sleep 2; up ;;
    *) echo "Usage: $0 {up|down|status|restart}" ;;
esac
