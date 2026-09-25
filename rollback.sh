#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# NotaServer Rollback — undo installer steps
# Usage: sudo bash rollback.sh [--last|--all|--full|--panic|--help]
# ═══════════════════════════════════════════════════════════════════════════
set -e
SETUP_DIR="/tmp/notaserver-setup"
STATE_FILE="$SETUP_DIR/setup.state"
ROLLBACK_LOG="$SETUP_DIR/rollback.log"
NETPLAN_BACKUP="$SETUP_DIR/netplan.backup"
UFW_RULES_FILE="$SETUP_DIR/ufw-rules.log"
DATA_ROOT="/var/lib/notaserver"
CONTAINER_NAME="notacontainer"
SYSTEMD_DNS_UNIT="/etc/systemd/system/notaserver-dns.service"
DNS_CONF_FILE="/etc/notaserver/dns/dnsmasq.conf"

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
    CHECK="✓"; ARROW="→"; WARN="⚠"; ERR="✗"
else
    RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; CHECK="+"; ARROW=">"; WARN="!"; ERR="X"
fi
ui_i() { echo -e "${CYAN}${ARROW} ${RESET}$1"; }
ui_s() { echo -e "${GREEN}${CHECK} ${RESET}$1"; }
ui_w() { echo -e "${YELLOW}${WARN} ${RESET}$1"; }
ui_e() { echo -e "${RED}${ERR} ${RESET}$1"; }

_lstate() { [ -f "$STATE_FILE" ] && while IFS='=' read -r k v; do [ -z "$k" ] && continue; export "$k=$v"; done < "$STATE_FILE"; }
_isdone() { local v="STEP_$(echo "$1" | tr 'a-z' 'A-Z')"; [ "${!v:-pending}" = "done" ]; }

rollback_last() {
    if [ ! -f "$ROLLBACK_LOG" ]; then ui_e "No rollback log found. Nothing to undo."; exit 1; fi
    local last_step=$(grep '^\[' "$ROLLBACK_LOG" | tail -1 | grep -oP '^\[\K[0-9]+')
    ui_i "Rolling back last step: $last_step"
    case "$last_step" in
        6) rollback_server ;;
        5) rollback_dns ;;
        4) rollback_firewall ;;
        3) rollback_tailscale ;;
        2) rollback_network ;;
        1) rollback_system ;;
        *) ui_e "Unknown step: $last_step"; exit 1 ;;
    esac
    # Remove that step from state
    if [ -f "$STATE_FILE" ]; then
        local step_name
        case "$last_step" in
            1) step_name="system" ;; 2) step_name="network" ;; 3) step_name="tailscale" ;;
            4) step_name="firewall" ;; 5) step_name="dns" ;; 6) step_name="server" ;;
        esac
        sed -i "/^STEP_${step_name^^}=done$/d" "$STATE_FILE" 2>/dev/null || true
        # Re-number subsequent steps in log? For simplicity, just remove the last action
        head -n -1 "$ROLLBACK_LOG" > "$ROLLBACK_LOG.tmp" && mv "$ROLLBACK_LOG.tmp" "$ROLLBACK_LOG"
    fi
    ui_s "Rolled back step $last_step ($step_name)"
}

rollback_all() {
    ui_i "Rolling back entire session..."
    [ -f "$ROLLBACK_LOG" ] || { ui_e "No rollback log. Nothing to undo."; exit 1; }
    # Undo in reverse order — read log and process from bottom up
    local steps=$(grep '^\[' "$ROLLBACK_LOG" | grep -oP '^\[\K[0-9]+' | tac)
    for s in $steps; do
        case "$s" in
            6) rollback_server ;;
            5) rollback_dns ;;
            4) rollback_firewall ;;
            3) rollback_tailscale ;;
            2) rollback_network ;;
            1) rollback_system ;;
        esac
    done
    # Clear state
    [ -f "$STATE_FILE" ] && > "$STATE_FILE"
    [ -f "$ROLLBACK_LOG" ] && > "$ROLLBACK_LOG"
    ui_s "Full session rollback complete"
}

rollback_full() {
    ui_i "Full uninstall — removing all NotaServer traces..."
    [ -f "$STATE_FILE" ] && _lstate
    
    # Server
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        ui_s "Removed container: $CONTAINER_NAME"
    fi
    rm -rf "$DATA_ROOT"
    ui_s "Removed $DATA_ROOT"
    
    # Homepage
    if [ -f "$DATA_ROOT/../html/index.html" ] && [ -f "$DATA_ROOT/html/index.html" ]; then
        # Don't remove if it might be the only copy
        ui_i "Note: /var/www/html/index.html not removed (may be in use)"
    fi
    
    # DNS
    if [ -f "$SYSTEMD_DNS_UNIT" ]; then
        systemctl stop notaserver-dns >/dev/null 2>&1 || true
        systemctl disable notaserver-dns >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DNS_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ui_s "Removed DNS service"
    fi
    if [ -d "$DNS_CONF_FILE" ] || [ -f "$DNS_CONF_FILE" ]; then
        rm -rf "$DNS_CONF_FILE"
        ui_s "Removed DNS config"
    fi
    # Only remove dnsmasq if we installed it (check if any other service uses it)
    if dpkg -l dnsmasq 2>/dev/null | grep -q '^ii' && ! systemctl list-unit-files 2>/dev/null | grep -q 'dnsmasq.*enabled'; then
        apt-get remove --purge -y dnsmasq >/dev/null 2>&1 || true
        ui_s "Removed dnsmasq package"
    fi
    
    # Firewall
    if [ -f "$UFW_RULES_FILE" ]; then
        while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            ufw delete "$rule" >/dev/null 2>&1 || true
        done < "$UFW_RULES_FILE"
        ui_s "Removed UFW rules"
    fi
    
    # Network
    if [ -f "$NETPLAN_BACKUP" ]; then
        cp "$NETPLAN_BACKUP" /etc/netplan/00-installer-config.yaml
        netplan apply >/dev/null 2>&1 || true
        ui_s "Restored network config"
    fi
    
    # Tailscale
    if command -v tailscale >/dev/null 2>&1; then
        tailscale down >/dev/null 2>&1 || true
        ui_i "Tailscale: down (package not removed — check if pre-existing)"
    fi
    
    rm -f "$STATE_FILE" "$ROLLBACK_LOG" "$UFW_RULES_FILE" "$NETPLAN_BACKUP"
    rm -rf "$SETUP_DIR"
    ui_s "Cleanup complete"
}

rollback_panic() {
    ui_i "Panic rollback — conservative undo of dangerous changes..."
    # Stop container
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        ui_s "Stopped and removed: $CONTAINER_NAME"
    fi
    # Restore network if backup exists
    if [ -f "$NETPLAN_BACKUP" ]; then
        cp "$NETPLAN_BACKUP" /etc/netplan/00-installer-config.yaml
        netplan apply >/dev/null 2>&1 || true
        ui_s "Network restored from backup"
    else
        ui_i "No netplan backup — network unchanged"
    fi
    # Stop DNS if service exists
    if [ -f "$SYSTEMD_DNS_UNIT" ]; then
        systemctl stop notaserver-dns >/dev/null 2>&1 || true
        systemctl disable notaserver-dns >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DNS_UNIT"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ui_s "DNS service stopped"
    fi
    ui_i "Panic rollback done. Check status: sudo bash $0 --status"
}

show_help() {
    echo "NotaServer Rollback"
    echo ""
    echo "Usage: sudo bash rollback.sh [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --last      Undo the last step only"
    echo "  --all       Undo entire installer session"
    echo "  --full      Full uninstall — remove all NotaServer traces"
    echo "  --panic     Conservative undo: stop container, restore network, stop DNS"
    echo "  --help      Show this help"
    echo ""
    echo "Rollback log: $ROLLBACK_LOG"
    echo "State file:   $STATE_FILE"
}

# Entry point
if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root."; echo "  sudo bash $0 [options]"; exit 1
fi

case "${1:-}" in
    --last) rollback_last ;;
    --all) rollback_all ;;
    --full) rollback_full ;;
    --panic) rollback_panic ;;
    --help|-h) show_help ;;
    *) show_help ;;
esac
