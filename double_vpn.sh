#!/bin/sh
# awg_chain_switch.sh – Toggle “all LAN via awg0 -> awg1” (state-aware)

##############################################################################
#  USER CONFIG (edit paths only if they differ)
##############################################################################
AWG_DIR="/data/usr/app/awg"

# Config for first tunnel (awg0)
CFG0="$AWG_DIR/amnezia_for_awg.conf"
IFCFG0="$AWG_DIR/awg0.conf"

# Config for second tunnel (awg1)
CFG1="$AWG_DIR/amnezia_for_awg1.conf"
IFCFG1="$AWG_DIR/awg1.conf"

AWG_BIN="$AWG_DIR/awg"
AWG_GO="$AWG_DIR/amneziawg-go"

LAN_NET="192.168.31.0/24"
LAN_BR="br-lan"
ROUTER_IP="192.168.31.1"
STATE_FILE="/tmp/awg_wan_info_double"      # stores WAN_GW  WAN_IF

# Enable DNS DNAT to the final tunnel's DNS? (0 = disable, 1 = enable)
ENABLE_DNS_NAT=1
##############################################################################

die()  { echo "❌ $*" >&2; exit 1; }
need() { [ -f "$1" ] || die "Missing file: $1"; }
root() { [ "$(id -u)" -eq 0 ] || die "This script must be run as root."; }

root
need "$CFG0"
need "$CFG1"

##############################################################################
# Parse static info from Amnezia configs
# Added `tr -d '\r'` to prevent errors from DOS/Windows line endings
##############################################################################
# Tunnel 0
WG_SERVER0=$(awk -F' = ' '/^Endpoint/ {print $2}' "$CFG0" | cut -d':' -f1 | tr -d '\r')
WG_ADDR0=$(awk -F' = ' '/^Address/ {print $2}' "$CFG0" | cut -d',' -f1 | tr -d ' \r')
DNS0=$(awk       -F' = ' '/^DNS/      {print $2}' "$CFG0" | cut -d',' -f1 | tr -d '\r')

# Tunnel 1
WG_SERVER1=$(awk -F' = ' '/^Endpoint/ {print $2}' "$CFG1" | cut -d':' -f1 | tr -d '\r')
WG_ADDR1=$(awk -F' = ' '/^Address/ {print $2}' "$CFG1" | cut -d',' -f1 | tr -d ' \r')
DNS1=$(awk       -F' = ' '/^DNS/      {print $2}' "$CFG1" | cut -d',' -f1 | tr -d '\r')

[ -z "$WG_SERVER0" ] && die "Could not parse Endpoint from $CFG0"
[ -z "$WG_SERVER1" ] && die "Could not parse Endpoint from $CFG1"

##############################################################################
# Helpers – create stripped awg interface configs
##############################################################################
build_ifcfgs() {
    if [ ! -f "$IFCFG0" ]; then
        awk '!/^Address/ && !/^DNS/' "$CFG0" > "$IFCFG0"
        echo "🔹 Created $IFCFG0"
    fi
    if [ ! -f "$IFCFG1" ]; then
        awk '!/^Address/ && !/^DNS/' "$CFG1" > "$IFCFG1"
        echo "🔹 Created $IFCFG1"
    fi
}

##############################################################################
# Helper – download binaries if missing
##############################################################################
ensure_bins() {
    [ -x "$AWG_BIN" ] && [ -x "$AWG_GO" ] && return
    echo "🔹 Downloading AmneziaWG binaries…"
    curl -L -o "$AWG_DIR/awg.tar.gz" \
         https://github.com/alexandershalin/amneziawg-be7000/raw/main/awg.tar.gz
    tar -xzvf "$AWG_DIR/awg.tar.gz" -C "$AWG_DIR"
    chmod +x "$AWG_DIR/"{awg,amneziawg-go}
    rm "$AWG_DIR/awg.tar.gz"
}

##############################################################################
# Helper – enable kernel IP forwarding
##############################################################################
enable_ip_forwarding() {
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 0 ]; then
        echo "🔹 Enabling kernel IP forwarding..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
    fi
}

##############################################################################
# Helpers – bring awg interfaces up
##############################################################################
start_awg0() {
    $AWG_GO awg0 >/dev/null 2>&1
    $AWG_BIN setconf awg0 "$IFCFG0"
    ip addr flush dev awg0 2>/dev/null
    ip addr add "$WG_ADDR0" dev awg0
    ip link set up awg0
}

start_awg1() {
    $AWG_GO awg1 >/dev/null 2>&1
    $AWG_BIN setconf awg1 "$IFCFG1"
    ip addr flush dev awg1 2>/dev/null
    ip addr add "$WG_ADDR1" dev awg1
    ip link set up awg1
}

##############################################################################
# Helpers – manage WAN state
##############################################################################
autodetect_wan() {
    DEF=$(ip r | awk '/^default/ {print $0; exit}')
    WAN_GW=$(echo "$DEF" | awk '{print $3}')
    WAN_IF=$(echo "$DEF" | awk '{print $5}')
    [ -n "$WAN_GW" ] && [ -n "$WAN_IF" ] || return 1
    return 0
}

save_wan_info() {
    echo "$WAN_GW $WAN_IF" > "$STATE_FILE"
}

load_wan_info() {
    if [ -f "$STATE_FILE" ]; then
        WAN_GW=$(awk '{print $1}' "$STATE_FILE")
        WAN_IF=$(awk '{print $2}' "$STATE_FILE")
    fi
}

##############################################################################
# Helpers – manage firewall rules
##############################################################################
flush_fw() {
    # Remove MSS clamping rule first
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg1 -j TCPMSS --set-mss 1380 2>/dev/null

    # Remove connection tracking rule
    iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

    if [ "$ENABLE_DNS_NAT" = 1 ]; then
        iptables -t nat -D PREROUTING -i $LAN_BR -p udp --dport 53 -j DNAT --to-destination ${DNS1}:53 2>/dev/null
        iptables -t nat -D PREROUTING -i $LAN_BR -p tcp --dport 53 -j DNAT --to-destination ${DNS1}:53 2>/dev/null
    fi
    iptables -t nat -D POSTROUTING -s $LAN_NET -o awg1 -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i $LAN_BR -o awg1 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i awg1 -o $LAN_BR -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i awg0 -o awg1 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i awg1 -o awg0 -j ACCEPT 2>/dev/null
}

add_fw() {
    # CRITICAL: Allow return traffic that we initiated. Insert at the top (position 1).
    iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # CRITICAL: Allow NEW traffic from the LAN to be forwarded out the VPN.
    # Insert this at position 2 to ensure it's hit before any default REJECT rules.
    iptables -C FORWARD -i $LAN_BR -o awg1 -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 2 -i $LAN_BR -o awg1 -j ACCEPT

    # Allow traffic to flow between the two tunnels
    iptables -C FORWARD -i awg0 -o awg1 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i awg0 -o awg1 -j ACCEPT
    iptables -C FORWARD -i awg1 -o awg0 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i awg1 -o awg0 -j ACCEPT

    # NAT (Masquerade) all outgoing LAN traffic on the final exit interface
    iptables -t nat -C POSTROUTING -s $LAN_NET -o awg1 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s $LAN_NET -o awg1 -j MASQUERADE

    # FIX MTU/MSS issues with chained tunnels by clamping the TCP Maximum Segment Size.
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg1 -j TCPMSS --set-mss 1380 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o awg1 -j TCPMSS --set-mss 1380

    # Intercept DNS requests and forward them to the final tunnel's DNS
    if [ "$ENABLE_DNS_NAT" = 1 ]; then
        iptables -t nat -C PREROUTING -i $LAN_BR -p udp --dport 53 -j DNAT --to-destination ${DNS1}:53 2>/dev/null || \
            iptables -t nat -A PREROUTING -i $LAN_BR -p udp --dport 53 -j DNAT --to-destination ${DNS1}:53
        iptables -t nat -C PREROUTING -i $LAN_BR -p tcp --dport 53 -j DNAT --to-destination ${DNS1}:53 2>/dev/null || \
            iptables -t nat -A PREROUTING -i $LAN_BR -p tcp --dport 53 -j DNAT --to-destination ${DNS1}:53
    fi
}

##############################################################################
# ACTION: up – switch all traffic to VPN chain
##############################################################################
do_up() {
    echo "=== Enabling VPN-chain mode (LAN -> awg1 -> awg0 -> WAN) ==="
    build_ifcfgs
    ensure_bins
    enable_ip_forwarding
    start_awg0
    start_awg1

    # Detect current WAN and save for future 'down' command
    autodetect_wan || die "Could not detect WAN default route."
    save_wan_info

    # CRITICAL: Pin WG server IPs to specific routes to avoid loops
    # 1. First server must go via physical WAN
    echo "🔹 Pinning $WG_SERVER0 via $WAN_GW"
    ip route replace "$WG_SERVER0"/32 via "$WAN_GW" dev "$WAN_IF"

    # Give awg0 a moment to connect before routing through it
    echo "🔹 Waiting for awg0 handshake..."
    sleep 3

    # 2. Second server must go via the first tunnel (awg0)
    echo "🔹 Pinning $WG_SERVER1 via awg0"
    ip route replace "$WG_SERVER1"/32 dev awg0

    # 3. All other traffic goes via the second tunnel (awg1)
    echo "🔹 Setting default route via awg1"
    ip route del default 2>/dev/null
    ip route add default dev awg1 scope link

    # Keep LAN-to-router traffic local (defensive)
    ip rule add from $LAN_NET to $ROUTER_IP lookup main pref 100 2>/dev/null

    add_fw
    echo "✅ All traffic now exits via awg1 -> awg0 (WAN info saved)."
}

##############################################################################
# ACTION: down – restore WAN default
##############################################################################
do_down() {
    echo "=== Restoring ISP route ==="
    load_wan_info
    if [ -z "$WAN_GW" ] || [ -z "$WAN_IF" ]; then
        die "No saved WAN info found in $STATE_FILE. Cannot restore route."
    fi

    # Delete custom rules and routes in reverse order of creation
    ip rule del from $LAN_NET to $ROUTER_IP lookup main pref 100 2>/dev/null
    ip route del default dev awg1 2>/dev/null
    ip route del "$WG_SERVER1"/32 dev awg0 2>/dev/null
    ip route del "$WG_SERVER0"/32 via "$WAN_GW" dev "$WAN_IF" 2>/dev/null

    flush_fw

    # Restore original WAN default route
    ip route add default via "$WAN_GW" dev "$WAN_IF"

    # Optionally bring tunnel interfaces down
    echo "🔹 Shutting down awg interfaces"
    ip link set down dev awg0 2>/dev/null
    ip link set down dev awg1 2>/dev/null
    rm -f "$STATE_FILE"

    echo "✅ Default route is now via $WAN_GW on $WAN_IF"
}

##############################################################################
# ACTION: status – show quick overview
##############################################################################
do_status() {
    echo "--- default route ---"
    ip r | grep '^default' || echo "(none)"
    echo
    echo "--- awg0 interface ---"
    ip -brief addr show awg0
    echo "--- route to WG server 0 ($WG_SERVER0) ---"
    ip r | grep "$WG_SERVER0" || echo "(no explicit /32 route)"
    echo
    echo "--- awg1 interface ---"
    ip -brief addr show awg1
    echo "--- route to WG server 1 ($WG_SERVER1) ---"
    ip r | grep "$WG_SERVER1" || echo "(no explicit /32 route)"
    echo
    echo "--- WAN state file ($STATE_FILE) ---"
    [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "(not found)"
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
