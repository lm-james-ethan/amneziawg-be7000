#!/bin/sh

# ==========================================
# AmneziaWG Firewall Manager (Up/Down)
# Usage: ./setup_firewall.sh [up|down]
# ==========================================

ACTION=$1
SCRIPT_PATH="/data/usr/app/awg/awg_start.sh"

setup_up() {
    echo ">>> APPLYING SETTINGS (UP)..."

    # 1. Allow Global Forwarding
    echo " -> Setting firewall forwarding to ACCEPT..."
    uci set firewall.@defaults[0].forward='ACCEPT'

    # 2. Register the Startup Script
    echo " -> Registering awg_start.sh in firewall..."
    uci delete firewall.awg0 2>/dev/null  # clear old if exists
    uci set firewall.awg0=include
    uci set firewall.awg0.type='script'
    uci set firewall.awg0.path="$SCRIPT_PATH"
    uci set firewall.awg0.enabled='1'

    # 3. Permission Check
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH"
        echo " -> Permissions verified for $SCRIPT_PATH"
    else
        echo " -> WARNING: $SCRIPT_PATH not found! Please check file."
    fi

    # 4. Save and Restart
    echo " -> Committing changes and restarting firewall..."
    uci commit firewall
    /etc/init.d/firewall restart
    echo ">>> SETUP COMPLETE. (Traffic allowed, Script registered)"
}

setup_down() {
    echo ">>> RESTORING ORIGINAL SETTINGS (DOWN)..."

    # 1. Revert Global Forwarding (Standard Default is REJECT)
    echo " -> Reverting firewall forwarding to REJECT..."
    uci set firewall.@defaults[0].forward='REJECT'

    # 2. Remove the Startup Script Registration
    echo " -> Removing awg_start.sh from firewall..."
    uci delete firewall.awg0 2>/dev/null

    # 3. Save and Restart
    echo " -> Committing changes and restarting firewall..."
    uci commit firewall
    /etc/init.d/firewall restart
    echo ">>> RESTORE COMPLETE. (Original settings applied)"
}

# Logic to choose action
case "$ACTION" in
    up)
        setup_up
        ;;
    down)
        setup_down
        ;;
    *)
        echo "Usage: $0 {up|down}"
        echo "  up   - Setup firewall forwarding and register script"
        echo "  down - Restore firewall defaults and remove script"
        exit 1
        ;;
esac
