#!/bin/sh
# awg_route_switch.sh - Toggle all LAN traffic via awg0

##############################################################################
# CONFIGURATION
##############################################################################
AWG_DIR="/data/usr/app/awg"
CFG="$AWG_DIR/amnezia_for_awg.conf"
IFCFG="$AWG_DIR/awg0.conf"
AWG_BIN="$AWG_DIR/awg"
AWG_GO="$AWG_DIR/amneziawg-go"
WATCHDOG_SCRIPT="$AWG_DIR/awg_watchdog.sh"
CLEAR_FW_SCRIPT="$AWG_DIR/clear_firewall_settings.sh"

# Networking Config
LAN_NET="192.168.31.0/24"     # Your LAN Subnet
LAN_BR="br-lan"               # Your LAN Interface
ROUTER_IP="192.168.31.1"
STATE_FILE="/tmp/awg_wan_info"

# URLs
URL_BIN="https://github.com/lm-james-ethan/amneziawg-be7000/raw/refs/heads/main/awg.tar.gz"
URL_WD="https://raw.githubusercontent.com/lm-james-ethan/amneziawg-be7000/refs/heads/main/awg_watchdog.sh"
URL_CLEAN="https://raw.githubusercontent.com/lm-james-ethan/amneziawg-be7000/refs/heads/main/clear_firewall_settings.sh"

# Set MTU
AWG_MTU=1280

##############################################################################
# HELPER FUNCTIONS
##############################################################################

die()  { echo "Error: $*" >&2; exit 1; }
root() { [ "$(id -u)" -eq 0 ] || die "Run as root"; }

ensure_files() {
    # 1. Binaries
    if [ ! -x "$AWG_BIN" ] || [ ! -x "$AWG_GO" ]; then
        echo "Downloading AmneziaWG binaries..."
        curl -L -o "$AWG_DIR/awg.tar.gz" "$URL_BIN" || die "Failed to download binaries"
        tar -xzvf "$AWG_DIR/awg.tar.gz" -C "$AWG_DIR"
        chmod +x "$AWG_DIR/awg" "$AWG_DIR/amneziawg-go"
        rm -f "$AWG_DIR/awg.tar.gz"
    fi

    # 2. Watchdog
    if [ ! -f "$WATCHDOG_SCRIPT" ]; then
        echo "Downloading watchdog script..."
        curl -L -o "$WATCHDOG_SCRIPT" "$URL_WD" || echo "Warning: Failed to download watchdog"
        chmod +x "$WATCHDOG_SCRIPT"
    fi

    # 3. Clear Firewall Script
    if [ ! -f "$CLEAR_FW_SCRIPT" ]; then
        echo "Downloading firewall cleaner..."
        curl -L -o "$CLEAR_FW_SCRIPT" "$URL_CLEAN" || echo "Warning: Failed to download cleaner"
        chmod +x "$CLEAR_FW_SCRIPT"
    fi
}

build_ifcfg() {
    [ -f "$CFG" ] || die "Main config $CFG not found!"
    if [ ! -f "$IFCFG" ]; then
        awk '!/^Address/ && !/^DNS/' "$CFG" > "$IFCFG"
        echo "Created $IFCFG"
    fi
    
    # Parse info for routing
    WG_SERVER=$(awk -F' = ' '/^Endpoint/ {print $2}' "$CFG" | cut -d':' -f1 | tr -d '\r')
    WG_ADDR=$(awk -F' = ' '/^Address/ {print $2}' "$CFG" | cut -d',' -f1 | tr -d '\r')
    DNS=$(awk -F' = ' '/^DNS/ {print $2}' "$CFG" | cut -d',' -f1 | tr -d '\r')
}

autodetect_wan() {
    DEF=$(ip r | awk '/^default/ {print $0; exit}')
    WAN_GW=$(echo "$DEF" | awk '{print $3}')
    WAN_IF=$(echo "$DEF" | awk '{print $5}')
    
    if [ -n "$WAN_GW" ] && [ -n "$WAN_IF" ]; then
        echo "$WAN_GW $WAN_IF" > "$STATE_FILE"
        return 0
    else
        return 1
    fi
}

cron_add() {
    CRON_CMD="* * * * * sh $WATCHDOG_SCRIPT > /dev/null 2>&1"
    if ! crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
        echo "Adding watchdog to cron..."
        (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    fi
}

cron_del() {
    if crontab -l 2>/dev/null | grep -qF "awg_watchdog.sh"; then
        echo "Removing watchdog from cron..."
        crontab -l 2>/dev/null | grep -vF "awg_watchdog.sh" | crontab -
    fi
}

##############################################################################
# ACTIONS
##############################################################################

do_up() {
    echo "=== Enabling VPN Mode ==="
    root
    ensure_files
    build_ifcfg

    # 1. Start Interface
    pkill -f amneziawg-go 2>/dev/null
    $AWG_GO awg0 >/dev/null 2>&1
    
    # Wait for interface
    count=0
    while ! ip link show awg0 >/dev/null 2>&1; do
        sleep 1
        count=$((count+1))
        [ "$count" -ge 10 ] && die "awg0 failed to appear"
    done

    $AWG_BIN setconf awg0 "$IFCFG"
    ip addr add "$WG_ADDR" dev awg0
    ip link set dev awg0 mtu $AWG_MTU
    ip link set up awg0

    # 2. Routing
    autodetect_wan || die "Cannot detect WAN gateway"
    read WAN_GW WAN_IF < "$STATE_FILE"

    # Route VPN traffic to real gateway
    ip route replace "$WG_SERVER"/32 via "$WAN_GW" dev "$WAN_IF"
    # Switch default route
    ip route del default 2>/dev/null
    ip route add default dev awg0 scope link
    # Fix local LAN access
    ip rule add from "$LAN_NET" to "$ROUTER_IP" lookup main pref 100 2>/dev/null

    # 3. Firewall
    # Forwarding
    iptables -C FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$LAN_BR" -o awg0 -j ACCEPT
    iptables -C FORWARD -i awg0 -o "$LAN_BR" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i awg0 -o "$LAN_BR" -j ACCEPT
    # Input
    iptables -C INPUT -i awg0 -j ACCEPT 2>/dev/null || iptables -A INPUT -i awg0 -j ACCEPT
    # Masquerade
    iptables -t nat -C POSTROUTING -s "$LAN_NET" -o awg0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$LAN_NET" -o awg0 -j MASQUERADE
    # MSS Clamping
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg0 -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg0 -j TCPMSS --clamp-mss-to-pmtu

    # DNS Redirection (Force VPN DNS)
    if [ -n "$DNS" ]; then
        iptables -t nat -C PREROUTING -p udp -s "$LAN_NET" --dport 53 -j DNAT --to-destination "${DNS}:53" 2>/dev/null || \
        iptables -t nat -A PREROUTING -p udp -s "$LAN_NET" --dport 53 -j DNAT --to-destination "${DNS}:53"
        iptables -t nat -C PREROUTING -p tcp -s "$LAN_NET" --dport 53 -j DNAT --to-destination "${DNS}:53" 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp -s "$LAN_NET" --dport 53 -j DNAT --to-destination "${DNS}:53"
    fi

    # 4. Enable Watchdog
    cron_add
    
    echo "VPN is UP. Watchdog active."
}

do_down() {
    echo "=== Disabling VPN Mode ==="
    root
    
    # 1. Disable Watchdog first to prevent auto-restart
    cron_del

    # 2. Restore Routing
    if [ -f "$STATE_FILE" ]; then
        read WAN_GW WAN_IF < "$STATE_FILE"
    else
        # Fallback if file missing
        WAN_GW=$(ip r | grep "$WG_SERVER" | awk '{print $3}')
        WAN_IF="eth3" # Adjust if needed or rely on autodetect failure
    fi

    if [ -n "$WAN_GW" ]; then
        ip route del default dev awg0 2>/dev/null
        ip route add default via "$WAN_GW" dev "$WAN_IF" metric 5 2>/dev/null
        # Remove specific VPN route
        ip route del "$WG_SERVER"/32 2>/dev/null
    fi

    # 3. Clean Firewall
    # If the clean script exists, use it
    if [ -x "$CLEAR_FW_SCRIPT" ]; then
        sh "$CLEAR_FW_SCRIPT"
    else
        # Manual fallback cleanup
        iptables -t nat -D POSTROUTING -s "$LAN_NET" -o awg0 -j MASQUERADE 2>/dev/null
        iptables -D INPUT -i awg0 -j ACCEPT 2>/dev/null
        # Flush NAT table to clear stuck connections
        conntrack -F >/dev/null 2>&1
    fi

    # 4. Kill Interface
    ip link set down awg0 2>/dev/null
    ip link del awg0 2>/dev/null
    pkill -f amneziawg-go 2>/dev/null
    
    echo "VPN is DOWN. Default route restored."
}

do_status() {
    echo "--- Interface ---"
    ip -brief addr show awg0 2>/dev/null || echo "awg0: DOWN"
    echo "--- Default Route ---"
    ip r | grep "^default"
    echo "--- Watchdog Cron ---"
    crontab -l 2>/dev/null | grep "awg_watchdog" || echo "Not scheduled"
}

##############################################################################
# MAIN ENTRY
##############################################################################
case "$1" in
    up)     do_up ;;
    down)   do_down ;;
    status) do_status ;;
    *)      echo "Usage: $0 {up|down|status}"; exit 1 ;;
esac
