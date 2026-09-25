#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# NotaServer Doctor — diagnostics and status check
# Usage: sudo bash doctor.sh [--status|--check|--cleanup|--help]
# ═══════════════════════════════════════════════════════════════════════════
set -e
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
ui_sec() { echo ""; echo -e "${BOLD}==>${RESET} $1"; echo -e "${DIM}──────────────────────────────────────────${RESET}"; }

CONTAINER_NAME="notacontainer"
DATA_ROOT="/var/lib/notaserver"
SYSTEMD_DNS_UNIT="/etc/systemd/system/notaserver-dns.service"
DNS_CONF_FILE="/etc/notaserver/dns/dnsmasq.conf"

check_root() { if [ "$(id -u)" -ne 0 ]; then echo "Must be run as root."; echo "  sudo bash $0 [options]"; exit 1; fi; }

check_container() {
    ui_sec "Notacontainer"
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
            ui_s "Container: running"
            local ports=$(docker port "$CONTAINER_NAME" 2>/dev/null | tr '\n' ' ')
            [ -n "$ports" ] && ui_i "Ports: $ports"
            local health=$(curl -sf --max-time 3 http://127.0.0.1:80 >/dev/null 2>&1 && echo "HTTP responding" || echo "not responding")
            ui_i "Status: $health"
        else
            ui_w "Container: stopped"
            ui_i "Start: docker start $CONTAINER_NAME"
        fi
    else
        ui_w "Container: not found"
        ui_i "Install with: sudo bash installer.sh"
    fi
    if [ -f "$DATA_ROOT/notacontainer/conf/nginx.conf" ]; then
        ui_s "Nginx config: present"
    else
        ui_w "Nginx config: missing"
    fi
    if [ -f "$DATA_ROOT/notacontainer/html/index.html" ]; then
        local sz=$(wc -c < "$DATA_ROOT/notacontainer/html/index.html")
        ui_s "Homepage: present ($sz bytes)"
    else
        ui_w "Homepage: missing"
    fi
    if [ -f "$DATA_ROOT/notacontainer/certs/server.crt" ]; then
        ui_s "Certificate: present"
    else
        ui_w "Certificate: missing"
    fi
}

check_dns() {
    ui_sec "DNS"
    if [ -f "$SYSTEMD_DNS_UNIT" ]; then
        if systemctl is-active --quiet notaserver-dns 2>/dev/null; then
            ui_s "DNS service: running"
        else
            ui_w "DNS service: not running"
            ui_i "Start: sudo systemctl start notaserver-dns"
        fi
        if [ -f "$DNS_CONF_FILE" ]; then
            ui_s "DNS config: present"
            local ip=$(grep "address=/notaserver/" "$DNS_CONF_FILE" 2>/dev/null | head -1 | sed 's/.*address=\/notaserver\///' | sed 's/\/.*//')
            [ -n "$ip" ] && ui_i "Resolves *.notaserver → $ip"
        else
            ui_w "DNS config: missing"
        fi
    else
        ui_i "DNS service: not installed"
    fi
    if command -v dnsmasq >/dev/null 2>&1; then
        ui_i "dnsmasq: installed"
    else
        ui_i "dnsmasq: not installed"
    fi
}

check_tailscale() {
    ui_sec "Tailscale"
    if command -v tailscale >/dev/null 2>&1; then
        local ver=$(tailscale version 2>/dev/null | grep -oP '[0-9.]+' | head -1 || echo "unknown")
        ui_i "Tailscale: installed ($ver)"
        if tailscale status 2>/dev/null | grep -q connected; then
            ui_s "Status: connected"
        else
            ui_w "Status: not connected"
            ui_i "Connect: sudo tailscale up"
        fi
    else
        ui_i "Tailscale: not installed"
    fi
}

check_firewall() {
    ui_sec "Firewall (UFW)"
    if command -v ufw >/dev/null 2>&1; then
        local status=$(ufw status 2>/dev/null || echo "unknown")
        if echo "$status" | grep -qi active; then
            ui_s "UFW: active"
            echo "$status" | grep -E "(Status|Anywhere|22|80|443)" | head -8 | sed 's/^/  /'
        else
            ui_w "UFW: inactive"
        fi
    else
        ui_i "UFW: not installed"
    fi
}

check_network() {
    ui_sec "Network"
    local iface=$(ip -o addr show | grep -v lo | head -1 | awk '{print $2}' | tr -d ':')
    ui_i "Interface: $iface"
    ip -o -4 addr show "$iface" 2>/dev/null | grep -v secondary | while read -r _ _ addr _ rest; do
        ui_i "IP: $addr $(echo "$rest" | grep -oP 'inet \K[\d.]+' | head -1)"
    done
    local gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
    [ -n "$gw" ] && ui_i "Gateway: $gw"
}

check_disk() {
    ui_sec "Disk"
    [ -d "$DATA_ROOT" ] && ui_i "Data root: $DATA_ROOT ($(du -sh "$DATA_ROOT" 2>/dev/null | awk '{print $1}'))" || ui_i "Data root: not found"
    df -h / | tail -1 | awk '{printf "  Root: %s used of %s (%s)\n", $3, $2, $5}'
}

show_summary() {
    echo ""
    ui_sec "Summary"
    local host=$(hostname -f 2>/dev/null || hostname)
    ui_i "Hostname: $host"
    ui_i "Homepage: https://$host"
    ui_i "Notacontainer: $(docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$" && echo 'running' || echo 'not running')"
    check_dns 2>/dev/null | grep -q "running" && ui_i "DNS: active" || ui_i "DNS: inactive"
}

do_cleanup() {
    ui_sec "Cleaning temp files"
    local found=0
    for d in /tmp/notaserver-setup /tmp/notaserver-*; do
        [ -e "$d" ] || continue
        if [ -d "$d" ]; then
            rm -rf "$d"; found=1; ui_i "Removed: $d"
        elif [ -f "$d" ]; then
            rm -f "$d"; found=1; ui_i "Removed: $d"
        fi
    done
    [ "$found" -eq 0 ] && ui_s "No temp files found"
    ui_s "Cleanup complete"
}

show_help() {
    cat << EOF
NotaServer Doctor — diagnostics and status

Usage: sudo bash doctor.sh [COMMAND]

Commands:
  (none)     Run all checks + cleanup
  --status   Full status report
  --check    Run all checks only
  --cleanup  Remove temp files only
  --help     Show this help
EOF
}

check_root
case "${1:-}" in
    --status) check_container; check_dns; check_tailscale; check_firewall; check_network; check_disk; show_summary ;;
    --check) check_container; check_dns; check_tailscale; check_firewall; check_network; check_disk ;;
    --cleanup) do_cleanup ;;
    --help|-h) show_help ;;
    *) check_container; check_dns; check_tailscale; check_firewall; check_network; check_disk; do_cleanup; show_summary ;;
esac
