#!/bin/sh
# /data/usr/app/awg/awg_start.sh

# ================= CONFIGURATION =================
CFG_FILE="amnezia_for_awg.conf"
# =================================================

DIR="/data/usr/app/awg"
CFG="$DIR/$CFG_FILE"
IFCFG="$DIR/awg0.conf"
WG_BIN="$DIR/amneziawg-go"
TOOLS_BIN="$DIR/awg"
STATE_FILE="/tmp/awg_wan_gw"  # File to remember the real Gateway

# --- Helper: Find Gateway ---
get_wan_info() {
    # 1. Try to read from saved state first
    if [ -f "$STATE_FILE" ]; then
        WAN_GW=$(cat "$STATE_FILE" | awk '{print $1}')
        WAN_IF=$(cat "$STATE_FILE" | awk '{print $2}')
    fi

    # 2. If state is empty/invalid, try to detect from current routing table
    # (Look for the route used to reach 1.1.1.1 or 8.8.8.8)
    if [ -z "$WAN_GW" ]; then
        ROUTE_INFO=$(ip route get 1.1.1.1 2>/dev/null | head -n 1)
        WAN_GW=$(echo "$ROUTE_INFO" | awk '{ for(i=1; i<=NF; i++) if ($i=="via") print $(i+1) }')
        WAN_IF=$(echo "$ROUTE_INFO" | awk '{ for(i=1; i<=NF; i++) if ($i=="dev") print $(i+1) }')
    fi
}

# --- ACTION: UP (Start/Fix) ---
do_up() {
    echo "--- Checking/Starting VPN ---"
    
    # 1. CRON: Ensure Watchdog is active
    if ! crontab -l 2>/dev/null | grep -q "awg_start.sh"; then
        echo " > Adding Watchdog to Cron..."
        (crontab -l 2>/dev/null; echo "* * * * * /data/usr/app/awg/awg_start.sh up") | crontab -
    fi

    # 2. INTERFACE: Start if missing
    if ! ip link show awg0 >/dev/null 2>&1; then
        echo " > Starting Interface..."
        
        # Save current WAN Gateway BEFORE we mess up the routing
        get_wan_info
        if [ -n "$WAN_GW" ] && [ -n "$WAN_IF" ]; then
            echo "$WAN_GW $WAN_IF" > "$STATE_FILE"
        fi

        # Prepare Config
        WG_ADDR=$(awk -F' = ' '/^Address/ {print $2}' "$CFG" | cut -d',' -f1 | tr -d '\r')
        awk '!/^Address/ && !/^DNS/' "$CFG" > "$IFCFG"

        killall amneziawg-go 2>/dev/null
        export WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KERNEL=1
        "$WG_BIN" awg0
        sleep 2
        "$TOOLS_BIN" setconf awg0 "$IFCFG"
        ip link set dev awg0 mtu 1280
        ip addr add "$WG_ADDR" dev awg0
        ip link set up awg0
    fi

    # 3. ROUTING: Fix if broken
    get_wan_info
    if [ -n "$WAN_GW" ]; then
        WG_SERVER=$(awk -F' = ' '/^Endpoint/ {print $2}' "$CFG" | cut -d':' -f1 | tr -d '\r')
        
        # Ensure VPN Server uses real Internet (Lock the tunnel)
        ip route add "$WG_SERVER"/32 via "$WAN_GW" dev "$WAN_IF" 2>/dev/null
        
        # Ensure Default Traffic uses VPN
        CURRENT_DEF=$(ip route show default | awk '{print $5}' | head -n 1)
        if [ "$CURRENT_DEF" != "awg0" ]; then
            echo " > Switching Default Route to VPN..."
            ip route del default
            ip route add default dev awg0
        fi
    fi

    # 4. FIREWALL: Fix if wiped
    iptables -t nat -C POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null
    if [ $? -ne 0 ]; then
        echo " > Applying Firewall Rules..."
        iptables -A FORWARD -i awg0 -j ACCEPT
        iptables -A FORWARD -o awg0 -j ACCEPT
        iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
    fi
}

# --- ACTION: DOWN (Stop) ---
do_down() {
    echo "--- Stopping VPN ---"
    
    # 1. Remove Cron
    crontab -l 2>/dev/null | grep -v "awg_start.sh" | crontab -
    
    # 2. Restore Routing (CRITICAL FIX)
    get_wan_info
    
    # Delete VPN route
    ip route del default dev awg0 2>/dev/null
    
    # Restore WAN route
    if [ -n "$WAN_GW" ] && [ -n "$WAN_IF" ]; then
        echo " > Restoring WAN: via $WAN_GW dev $WAN_IF"
        ip route add default via "$WAN_GW" dev "$WAN_IF" 2>/dev/null
        
        # Remove the locked route for the server
        WG_SERVER=$(awk -F' = ' '/^Endpoint/ {print $2}' "$CFG" | cut -d':' -f1 | tr -d '\r')
        ip route del "$WG_SERVER"/32 2>/dev/null
    else
        echo " ! WARNING: Could not find original Gateway. You may need to reboot."
    fi

    # 3. Remove Firewall Rules
    iptables -D FORWARD -i awg0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o awg0 -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o awg0 -j MASQUERADE 2>/dev/null

    # 4. Kill Interface
    ip link set down awg0 2>/dev/null
    ip link del awg0 2>/dev/null
    killall amneziawg-go 2>/dev/null
    rm -f "$STATE_FILE"
    echo "VPN Stopped."
}

# --- ACTION: STATUS ---
do_status() {
    echo "=== VPN STATUS ==="
    if ip link show awg0 >/dev/null 2>&1; then
        echo "[Interface] UP"
        ip -brief addr show awg0
        echo ""
        echo "[Firewall NAT]"
        iptables -t nat -S | grep awg0 || echo "MISSING!"
        echo ""
        echo "[Ping Test]"
        ping -c 2 -W 2 -I awg0 1.1.1.1 2>/dev/null | grep "ttl=" || echo "Ping Failed"
    else
        echo "[Interface] DOWN"
    fi
}

# --- MAIN LOGIC ---
case "$1" in
    down)   do_down ;;
    status) do_status ;;
    up|*)   do_up ;;
esac
