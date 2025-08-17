#!/bin/sh
# awg_route_switch.sh – Toggle “YouTube via WAN, rest via awg0” (state-aware)

##############################################################################
#  USER CONFIG (edit paths only if they differ)
##############################################################################
AWG_DIR="/data/usr/app/awg"
CFG="$AWG_DIR/amnezia_for_awg.conf"
IFCFG="$AWG_DIR/awg0.conf"
AWG_BIN="$AWG_DIR/awg"
AWG_GO="$AWG_DIR/amneziawg-go"

LAN_NET="192.168.31.0/24"
LAN_BR="br-lan"
ROUTER_IP="192.168.31.1"
STATE_FILE="/tmp/awg_wan_info"      # stores WAN_GW  WAN_IF

# Enable DNS DNAT? (0 = disable, 1 = enable)
# Note: If enabled, all DNS goes to WG DNS. Disable if you want YouTube DNS to bypass.
ENABLE_DNS_NAT=1
##############################################################################

die()  { echo "? $*" >&2; exit 1; }
need() { [ -f "$1" ] || die "Missing file: $1"; }
root() { [ "$(id -u)" -eq 0 ] || die "Run as root"; }

root; need "$CFG"

##############################################################################
# Parse static info from Amnezia config
##############################################################################
WG_SERVER=$(awk -F' = ' '/^Endpoint/ {print $2}' "$CFG" | cut -d':' -f1)
WG_ADDR=$(awk   -F' = ' '/^Address/  {print $2}' "$CFG")
DNS=$(awk       -F' = ' '/^DNS/      {print $2}' "$CFG" | cut -d',' -f1)

##############################################################################
# Helper – create stripped awg0.conf
##############################################################################
build_ifcfg() {
    if [ ! -f "$IFCFG" ]; then
        awk '!/^Address/ && !/^DNS/' "$CFG" > "$IFCFG"
        echo "? Created $IFCFG"
    fi
}

##############################################################################
# Helper – download binaries if missing
##############################################################################
ensure_bins() {
    [ -x "$AWG_BIN" ] && [ -x "$AWG_GO" ] && return
    echo "Downloading AmneziaWG binaries…"
    curl -L -o "$AWG_DIR/awg.tar.gz" \
         https://github.com/alexandershalin/amneziawg-be7000/raw/main/awg.tar.gz  
    tar -xzvf "$AWG_DIR/awg.tar.gz" -C "$AWG_DIR"
    chmod +x "$AWG_DIR/"{awg,amneziawg-go}
    rm "$AWG_DIR/awg.tar.gz"
}

##############################################################################
# Helper – bring awg0 up
##############################################################################
start_awg() {
    $AWG_GO awg0 >/dev/null 2>&1
    $AWG_BIN setconf awg0 "$IFCFG"
    ip addr flush dev awg0 2>/dev/null
    ip addr add "$WG_ADDR" dev awg0
    ip link set up awg0
}

##############################################################################
# Helper – detect current default route (returns WAN_GW, WAN_IF)
##############################################################################
autodetect_wan() {
    DEF=$(ip r | awk '/^default/ {print $0; exit}')
    WAN_GW=$(echo "$DEF" | awk '{print $3}')
    WAN_IF=$(echo "$DEF" | awk '{print $5}')
    [ -n "$WAN_GW" ] && [ -n "$WAN_IF" ] || return 1
    return 0
}

##############################################################################
# Helper – save WAN info
##############################################################################
save_wan_info() {
    echo "$WAN_GW $WAN_IF" > "$STATE_FILE"
}

##############################################################################
# Helper – load WAN info
##############################################################################
load_wan_info() {
    if [ -f "$STATE_FILE" ]; then
        WAN_GW=$(awk '{print $1}' "$STATE_FILE")
        WAN_IF=$(awk '{print $2}' "$STATE_FILE")
    fi
}

##############################################################################
# Helper – firewall rules (idempotent)
##############################################################################
add_fw() {
    iptables -C FORWARD -i $LAN_BR -o awg0 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i $LAN_BR -o awg0 -j ACCEPT
    iptables -C FORWARD -i awg0 -o $LAN_BR -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i awg0 -o $LAN_BR -j ACCEPT
    iptables -t nat -C POSTROUTING -s $LAN_NET -o awg0 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s $LAN_NET -o awg0 -j MASQUERADE

    if [ "$ENABLE_DNS_NAT" = 1 ]; then
        iptables -t nat -C PREROUTING -p udp -s $LAN_NET --dport 53 -j DNAT --to-destination ${DNS}:53 2>/dev/null || \
            iptables -t nat -A PREROUTING -p udp -s $LAN_NET --dport 53 -j DNAT --to-destination ${DNS}:53
        iptables -t nat -C PREROUTING -p tcp -s $LAN_NET --dport 53 -j DNAT --to-destination ${DNS}:53 2>/dev/null || \
            iptables -t nat -A PREROUTING -p tcp -s $LAN_NET --dport 53 -j DNAT --to-destination ${DNS}:53
    fi
}

flush_dns_nat() {
    if [ "$ENABLE_DNS_NAT" = 1 ]; then
        iptables -t nat -D PREROUTING -p udp -s $LAN_NET --dport 53 -j DNAT --to-destination ${DNS}:53 2>/dev/null
        iptables -t nat -D PREROUTING -p tcp -s $LAN_NET --dport 53 -j DNAT --to-destination ${DNS}:53 2>/dev/null
    fi
    iptables -t nat -D POSTROUTING -s $LAN_NET -o awg0 -j MASQUERADE 2>/dev/null
}

##############################################################################
# ACTION: up – split routing: YouTube via WAN, rest via awg0
##############################################################################
do_up() {
    echo "=== Enabling split routing: YouTube via WAN, rest via awg0 ==="
    build_ifcfg
    ensure_bins
    start_awg

    # Detect WAN and save for future down
    autodetect_wan || die "Could not detect WAN default route."
    save_wan_info

    # Ensure WG server is reachable outside tunnel
    ip route replace "$WG_SERVER"/32 via "$WAN_GW" dev "$WAN_IF"

    # === Load YouTube CIDRs and route them via WAN ===
    YOUTUBE_CIDR_FILE="/data/usr/app/awg/cidr4.txt"
    if [ -f "$YOUTUBE_CIDR_FILE" ]; then
        echo "Loading YouTube CIDRs from $YOUTUBE_CIDR_FILE..."
        while IFS= read -r cidr; do
            # Trim whitespace
            cidr=$(echo "$cidr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Skip empty lines and comments
            [ -z "$cidr" ] && continue
            echo "$cidr" | grep -qE '^(#|;|$)' && continue

            # Validate CIDR format (basic)
            if echo "$cidr" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}$'; then
                echo "Routing $cidr via WAN ($WAN_GW on $WAN_IF)"
                ip route replace "$cidr" via "$WAN_GW" dev "$WAN_IF" metric 10
            else
                echo "Invalid CIDR skipped: $cidr" >&2
            fi
        done < "$YOUTUBE_CIDR_FILE"
    else
        echo "Warning: YouTube CIDR file not found: $YOUTUBE_CIDR_FILE" >&2
    fi

    # === Set default route to awg0 (all other traffic goes through tunnel) ===
    ip route del default 2>/dev/null
    ip route add default dev awg0 scope link

    # Keep LAN-to-router local (defensive)
    ip rule add from $LAN_NET to $ROUTER_IP lookup main pref 100 2>/dev/null || true

    # Apply firewall rules
    add_fw

    echo "? ✅ Split routing active:"
    echo "   - YouTube (from cidr4.txt) → via $WAN_IF ($WAN_GW)"
    echo "   - All other traffic → via awg0"
}

##############################################################################
# ACTION: down – restore full WAN default
##############################################################################
do_down() {
    echo "=== Restoring full ISP route (disabling split routing) ==="

    # Attempt to load saved WAN info
    load_wan_info

    # If file missing, fall back to auto-detect
    if [ -z "$WAN_GW" ] || [ -z "$WAN_IF" ]; then
        autodetect_wan || die "No saved WAN info and cannot auto-detect."
    fi

    # Remove all default routes
    while ip route | grep -q '^default'; do
        ip route del default 2>/dev/null || break
    done

    # Remove explicit routes for YouTube (optional: can be skipped, less clean)
    YOUTUBE_CIDR_FILE="/data/usr/app/awg/cidr4.txt"
    if [ -f "$YOUTUBE_CIDR_FILE" ]; then
        while IFS= read -r cidr; do
            cidr=$(echo "$cidr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$cidr" ] && continue
            echo "$cidr" | grep -qE '^(#|;|$)' && continue
            ip route del "$cidr" via "$WAN_GW" dev "$WAN_IF" 2>/dev/null || true
        done < "$YOUTUBE_CIDR_FILE"
    fi

    # Remove pin to WG server
    ip route del "$WG_SERVER"/32 via "$WAN_GW" dev "$WAN_IF" 2>/dev/null

    # Flush DNS NAT rules
    flush_dns_nat

    # Restore original default route
    ip route add default via "$WAN_GW" dev "$WAN_IF" metric 5

    # Optionally bring down awg0
    # ip link set down awg0

    echo "? Default route restored via $WAN_GW on $WAN_IF"
}

##############################################################################
# ACTION: status – show quick overview
##############################################################################
do_status() {
    echo "-- default route --"
    ip r | grep '^default' || echo "(none)"

    echo "-- awg0 address --"
    ip -brief addr show awg0 || echo "(not up)"

    echo "-- route to WG server ($WG_SERVER) --"
    ip r | grep "$WG_SERVER" || echo "(no explicit /32 route)"

    echo "-- YouTube CIDR routes (via WAN) --"
    YOUTUBE_CIDR_FILE="/data/usr/app/awg/cidr4.txt"
    if [ -f "$YOUTUBE_CIDR_FILE" ]; then
        head_count=0
        while IFS= read -r cidr; do
            cidr=$(echo "$cidr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$cidr" ] && continue
            echo "$cidr" | grep -qE '^(#|;|$)' && continue
            ip route | grep -q "^$cidr " && echo "✅ $cidr" || echo "⏳ $cidr (not routed)"
            head_count=$((head_count + 1))
            [ $head_count -ge 10 ] && echo "... (showing first 10)" && break
        done < "$YOUTUBE_CIDR_FILE"
    else
        echo "YouTube CIDR file missing: $YOUTUBE_CIDR_FILE"
    fi
}

##############################################################################
# MAIN
##############################################################################
case "$1" in
    up)     do_up ;;
    down)   do_down ;;
    status) do_status ;;
    *)      echo "Usage: $0 {up|down|status}"; exit 1 ;;
esac
