#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# NotaServer Installer — Phase 1
# Single nginx container (notacontainer) serving the homepage.
# Flow: system → network → tailscale → firewall → dns → server
# ═══════════════════════════════════════════════════════════════════════════
set -e; set -o pipefail
unset PYTHONPATH 2>/dev/null || true; unset PYTHONHOME 2>/dev/null || true

# ── Paths ───────────────────────────────────────────────────────────────────
SETUP_DIR="/tmp/notaserver-setup"; STATE_FILE="$SETUP_DIR/setup.state"
ROLLBACK_LOG="$SETUP_DIR/rollback.log"; NETPLAN_BACKUP="$SETUP_DIR/netplan.backup"
UFW_RULES_FILE="$SETUP_DIR/ufw-rules.log"
DATA_ROOT="/var/lib/notaserver"; NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
DOCKER_IMAGE="nginx:stable-alpine"; CONTAINER_NAME="notacontainer"
CERTS_DIR="$DATA_ROOT/notacontainer/certs"; CONF_DIR="$DATA_ROOT/notacontainer/conf"
HTML_DIR="$DATA_ROOT/notacontainer/html"; LOGS_DIR="$DATA_ROOT/notacontainer/logs"
SITES_DIR="$DATA_ROOT/notacontainer/sites"
SYSTEMD_DNS_UNIT="/etc/systemd/system/notaserver-dns.service"
DNS_CONF_DIR="/etc/notaserver/dns"; DNS_CONF_FILE="$DNS_CONF_DIR/dnsmasq.conf"
HOMEPAGE_SOURCE="${HOMEPAGE_SOURCE:-https://github.com/launchlean/notaserver/raw/main/index.html}"
INSTALLER_PATH="${INSTALLER_PATH:-/tmp/notaserver-setup/installer.sh}"

# ── Colours ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    CYAN='\033[0;36m'; GREY='\033[90m'
    CHECK="✓"; ARROW="→"; WARN="⚠"; ERR="✗"; BULL="○"
else
    RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; GREY=""
    CHECK="+"; ARROW=">"; WARN="!"; ERR="X"; BULL="o"
fi

# ── UI ──────────────────────────────────────────────────────────────────────
ui_h() { echo ""; echo -e "${BOLD}${CYAN}"; echo "╔══════════════════════════════════════════════════════════════╗"; echo "║         $1                   ║"; echo "╚══════════════════════════════════════════════════════════════╝"; echo -e "${RESET}"; echo ""; }
ui_i() { echo -e "${CYAN}${ARROW} ${RESET}$1"; }
ui_s() { echo -e "${GREEN}${CHECK} ${RESET}$1"; }
ui_w() { echo -e "${YELLOW}${WARN} ${RESET}$1"; }
ui_e() { echo -e "${RED}${ERR} ${RESET}$1"; }
ui_div() { echo -e "${DIM}──────────────────────────────────────────────────────────────${RESET}"; }
ui_st() { case "$1" in check) echo -e "  ${DIM}Checking:${RESET} $2" ;; progress) echo -e "  ${CYAN}${ARROW} ${RESET}$2" ;; done) echo -e "  ${GREEN}${CHECK} ${RESET}$2" ;; pending) echo -e "  ${YELLOW}${BULL} ${RESET}$2" ;; fail) echo -e "  ${RED}${ERR} ${RESET}$2" ;; esac; }

# ── Input helpers ───────────────────────────────────────────────────────────
_ti() { local p="$1" d="$2" r
    if [ -t 0 ]; then
        echo -n "$p"; [ -n "$d" ] && echo -n " [$d]: " || echo -n ": "
        read -r r; [ -z "$r" ] && r="$d"; echo "$r"
    elif echo >/dev/tty 2>/dev/null; then
        echo -n "$p" >/dev/tty
        [ -n "$d" ] && echo -n " [$d]: " >/dev/tty || echo -n ": " >/dev/tty
        read -r r </dev/tty
        [ -z "$r" ] && r="$d"
        echo "$r"
    else
        [ -n "$d" ] && echo "$d" || echo ""
    fi
}

_tm() { local t="$1"; shift; local o=("$@"); echo ""; echo "$t"; echo "──────────────────────────────────────────────────────────────"; local i=1; for x in "${o[@]}"; do echo "  $i. $x"; i=$((i+1)); done; echo ""; local n; n=$(_rmc "${#o[@]}"); echo "${o[$((n-1))]}"; }

_tc() { local m="$1" d="${2:-y}" r
    echo ""; echo "$m"; echo -n "  [${d}/n]: "
    if ! read -r r; then
        # Non-interactive: use default
        [ -n "$d" ] && r="$d"
    fi
    case "${r:-$d}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        [nN]|[nN][oO]) return 1 ;;
        *) return 1 ;;
    esac
}

_rmc() { local mx="$1" c
    c=$(_ti "Select option" "")
    if [ -z "$c" ]; then
        # Non-interactive: fall back to env or fail
        if [ -n "${INSTALL_TYPE:-}" ]; then
            echo "$INSTALL_TYPE"
            return 0
        fi
        ui_e "No interactive input available (non-TTY session)."
        ui_i "Set INSTALL_TYPE=1|2|3 or run interactively."
        return 1
    fi
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$mx" ]; then
        echo "$c"; return 0
    fi
    ui_e "Enter a number between 1 and $mx"
    return 1
}

_ws() { local t="$1"; shift; local o=("$@"); local n=${#o[@]}; local a=(); local i; for i in "${!o[@]}"; do a+=("$((i+1))" "${o[$i]}"); done; local ch; ch=$(whiptail --clear --title "$t" --menu "" 15 65 "$n" "${a[@]}" 3>&1 1>&2 2>&3); if [ $? -ne 0 ]; then echo ""; return 1; fi; echo "$ch"; }

_wc() { whiptail --clear --title "NotaServer" --yesno "$2" 12 60 --default-button "$3" 3>&1 1>&2 2>&3; return $?; }

_wi() { local r; r=$(whiptail --clear --title "NotaServer" --inputbox "$2" 12 60 "$3" 3>&1 1>&2 2>&3); if [ $? -ne 0 ]; then echo ""; return 1; fi; echo "$r"; }

_ac() { local t="$1"; shift; local o=("$@"); if command -v whiptail >/dev/null 2>&1 && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then local r; r=$(_ws "$t" "${o[@]}"); [ -z "$r" ] && { ui_i "Cancelled."; exit 0; }; echo "$r"; else _tm "$t" "${o[@]}"; fi; }

_ay() { local m="$1" d="${2:-y}"; if command -v whiptail >/dev/null 2>&1 && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then _wc "NotaServer" "$m" "$( [ "$d" = "y" ] && echo "Yes" || echo "No" )"; return $?; else _tc "$m" "$d"; return $?; fi; }

_at() { local p="$1" d="$2"; if command -v whiptail >/dev/null 2>&1 && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then local r; r=$(_wi "NotaServer" "$p" "$d"); [ -z "$r" ] && { ui_i "Cancelled."; exit 0; }; echo "$r"; else _ti "$p" "$d"; fi; }

# ── State ───────────────────────────────────────────────────────────────────
_init_dir() { mkdir -p "$SETUP_DIR"; }
_wstate() { echo "$1=$2" >> "$STATE_FILE"; }
_lstate() { [ -f "$STATE_FILE" ] && while IFS='=' read -r k v; do [ -z "$k" ] && continue; export "$k=$v"; done < "$STATE_FILE"; }
_mkdone() { local s="$1"; _wstate "STEP_${s^^}=done"; ui_st done "Step ($s) complete"; }
_log() { echo "$1" >> "$ROLLBACK_LOG"; }
_isdone() { local v="STEP_$(echo "$1" | tr 'a-z' 'A-Z')"; [ "${!v:-pending}" = "done" ]; }

# ── System checks ───────────────────────────────────────────────────────────
_ckroot() { if [ "$(id -u)" -ne 0 ]; then ui_e "Must be run as root."; ui_i "       sudo bash $0"; exit 1; fi; }
_ckubuntu() { if [ -f /etc/os-release ]; then . /etc/os-release; if [ "$ID" = "ubuntu" ] && [ "$VERSION_ID" = "22.04" ]; then ui_s "Ubuntu 22.04"; else ui_e "Unsupported: $ID $VERSION_ID"; exit 1; fi; else ui_e "Cannot detect OS"; exit 1; fi; }
_cknet() { if ! curl -sf --max-time 5 https://github.com >/dev/null 2>&1; then ui_e "No internet"; exit 1; fi; }
_dnet() { local iface=""; for i in eth0 ens3 ens33 enp0s3 enp0s8 enp4s0; do ip addr show "$i" >/dev/null 2>&1 && { iface="$i"; break; }; done; [ -z "$iface" ] && iface=$(ip -o addr show | grep -v lo | head -1 | awk '{print $2}' | tr -d ':'); local ip=$(ip -o -4 addr show "$iface" 2>/dev/null | grep -v secondary | head -1 | awk '{print $4}' | cut -d/ -f1); local cidr=$(ip -o -4 addr show "$iface" 2>/dev/null | grep -v secondary | head -1 | awk '{print $4}' | cut -d/ -f2); local gw=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1); local dns=$(grep -r 'nameserver' /etc/resolv.conf 2>/dev/null | head -1 | awk '{print $2}' || echo "$gw"); CURRENT_IFACE="$iface"; CURRENT_IP="$ip"; CURRENT_CIDR="${cidr:-24}"; CURRENT_GW="$gw"; CURRENT_DNS="${dns:-$gw}"; }


# ── Apt lock handling ───────────────────────────────────────────────────────
_apt_ready() {
    local timeout="${1:-60}" waited=0
    while [ $waited -lt $timeout ]; do
        # Check if any apt/dpkg/unattended process is running
        local blocker=$(pgrep -af 'apt|dpkg|unattended-upgrade' 2>/dev/null | grep -v pgrep | grep -v "bash -c" | head -1)
        if [ -z "$blocker" ]; then
            # No blocker — try to acquire lock
            if apt-get update -qq >/dev/null 2>&1; then
                return 0
            fi
            # Lock files may still exist without a process — clean them
            rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock \
                /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
            if apt-get update -qq >/dev/null 2>&1; then
                return 0
            fi
        fi
        # Has blocker — try to clear stale locks and wait
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock \
            /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null
        dpkg --configure -a >/dev/null 2>&1 || true
        sleep 2; waited=$((waited + 2))
    done
    ui_e "apt is blocked and could not be unlocked within ${timeout}s"
    ui_i "Check: ps aux | grep -E 'apt|dpkg|unattended'"
    return 1
}

# ── Step 1: System prep ─────────────────────────────────────────────────────
step_system() {
    ui_h "STEP 1 — SYSTEM PREPARATION"
    ui_st progress "Preparing package manager (checking for locks...)"
    if ! _apt_ready 90; then
        ui_e "Cannot proceed — apt package manager is blocked."
        ui_i "Resolve the blocking process and re-run: sudo bash $INSTALLER_PATH --resume"
        _log "[1] apt: BLOCKED — cannot proceed"
        exit 1
    fi
    _log "[1] apt-update: done"; ui_s "Package lists updated"
    local want_upgrade="no" want_tools="no"
    if [ "${INSTALL_TYPE:-custom}" != "quick" ]; then
        _ay "Upgrade existing packages?" "no" && want_upgrade="yes"; echo ""
        _ay "Install useful tools (nano, curl, jq, net-tools, ufw, fail2ban, htop, rsync, tmux)?" "yes" && want_tools="yes"; echo ""
    fi
    if [ "$want_upgrade" = "yes" ]; then
        ui_st progress "Upgrading packages"
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq >/dev/null 2>&1 || ui_w "Some upgrades may have failed"
        _log "[1] apt-upgrade: yes"; ui_s "Packages upgraded"
    else _log "[1] apt-upgrade: no"; fi
    if [ "$want_tools" = "yes" ]; then
        ui_st progress "Installing useful tools"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nano curl jq net-tools ufw fail2ban htop rsync tmux >/dev/null 2>&1 || ui_w "Some tools may have failed"
        _log "[1] tools: yes"; ui_s "Useful tools installed"
    else _log "[1] tools: no"; fi
    if command -v docker >/dev/null 2>&1; then
        ui_s "Docker: already installed ($(docker --version 2>/dev/null | grep -oP '[0-9.]+' | head -1 || echo 'unknown'))"
        _log "[1] docker: already-present"
    else
        ui_st progress "Installing Docker"
        if curl -fsSL https://get.docker.com | sh >/dev/null 2>&1; then
            systemctl enable docker >/dev/null 2>&1 || true; systemctl start docker >/dev/null 2>&1 || true
            ui_s "Docker installed"; _log "[1] docker: installed"
        else  ui_e "Docker install failed"; _log "[1] docker: failed"; exit 1; fi
    fi
    _mkdone "system"
}

# ── Step 2: Network (static IP) ─────────────────────────────────────────────
step_network() {
    ui_h "STEP 2 — NETWORK"
    _dnet
    ui_i "Current network configuration:"
    echo "  Interface:  $CURRENT_IFACE"
    echo "  IP:         ${CURRENT_IP}/${CURRENT_CIDR}"
    echo "  Gateway:    $CURRENT_GW"
    echo "  DNS:        $CURRENT_DNS"
    echo ""
    if ! _ay "Set a static IP on this server?" "no"; then
        ui_i "Keeping DHCP — no static IP configured"
        _log "[2] static-ip: skipped"
        _wstate "STEP_NETWORK=done"; _wstate "STEP_NETWORK_IP_CHANGED=no"; _mkdone "network"; return 0
    fi
    ui_i ""; ui_i "Enter the static IP configuration (press Enter to accept current value):"; echo ""
    local new_ip new_cidr new_gw new_dns
    new_ip=$(_at "Static IP" "$CURRENT_IP")
    new_cidr=$(_at "Netmask (CIDR, e.g. 24)" "$CURRENT_CIDR")
    new_gw=$(_at "Gateway" "$CURRENT_GW")
    new_dns=$(_at "DNS server" "$CURRENT_DNS")
    ui_i ""; ui_st check "Validating..."
    if ! [[ "$new_cidr" =~ ^[0-9]+$ ]] || [ "$new_cidr" -lt 8 ] || [ "$new_cidr" -gt 30 ]; then
        ui_e "Invalid netmask/CIDR: $new_cidr (must be 8-30)"; _log "[2] validation: failed (cidr)"; exit 1; fi
    if ! [[ "$new_ip" =~ ^([0-9]+\.){3}[0-9]+$ ]]; then
        ui_e "Invalid IP: $new_ip"; _log "[2] validation: failed (ip format)"; exit 1; fi
    local gw_prefix=$((0xFFFFFFFF << (32 - new_cidr)))
    local ip_num=0 gw_num=0
    IFS='.' read -r i1 i2 i3 i4 <<< "$new_ip"; ip_num=$(( (i1<<24)+(i2<<16)+(i3<<8)+i4 ))
    IFS='.' read -r g1 g2 g3 g4 <<< "$new_gw"; gw_num=$(( (g1<<24)+(g2<<16)+(g3<<8)+g4 ))
    if [ $((ip_num & gw_prefix)) -ne $((gw_num & gw_prefix)) ]; then
        ui_e "Gateway $new_gw not in same subnet as $new_ip/$new_cidr"; _log "[2] validation: failed (gateway subnet)"; exit 1; fi
    ui_s "Validation passed"
    if [ -f "$NETPLAN_FILE" ]; then cp "$NETPLAN_FILE" "$NETPLAN_BACKUP"; _log "[2] netplan-backup: $NETPLAN_BACKUP"; ui_s "Netplan backed up to $NETPLAN_BACKUP"; else ui_w "No existing netplan at $NETPLAN_FILE"; _log "[2] netplan-backup: none"; fi
    ui_st progress "Writing new network configuration"
    cat > "$NETPLAN_FILE" << NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    $CURRENT_IFACE:
      dhcp4: no
      addresses:
        - ${CURRENT_IP}/${CURRENT_CIDR}    # existing (kept for transition)
        - ${new_ip}/${new_cidr}            # new
      routes:
        - to: default
          via: $new_gw
      nameservers:
        addresses:
          - $new_dns
NETPLAN
    _log "[2] netplan-new: written (2-IP)"
    ui_st progress "Applying network configuration"
    if ! netplan apply >/dev/null 2>&1; then
        ui_e "netplan apply failed"; _log "[2] netplan-apply: FAILED"
        [ -f "$NETPLAN_BACKUP" ] && cp "$NETPLAN_BACKUP" "$NETPLAN_FILE" && netplan apply >/dev/null 2>&1 || true && ui_w "Reverted" && exit 1; fi
    _log "[2] netplan-apply: ok"
    sleep 2
    local vip=$(ip -o -4 addr show "$CURRENT_IFACE" 2>/dev/null | grep -v secondary | grep -q "$new_ip" && echo yes || echo no)
    local vgw=$(ping -c 1 -W 2 "$new_gw" >/dev/null 2>&1 && echo yes || echo no)
    if [ "$vip" != "yes" ]; then
        ui_e "New IP $new_ip not found after apply"; _log "[2] verify: FAILED (ip)"
        [ -f "$NETPLAN_BACKUP" ] && cp "$NETPLAN_BACKUP" "$NETPLAN_FILE" && netplan apply >/dev/null 2>&1 || true && ui_w "Reverted" && exit 1; fi
    [ "$vgw" != "yes" ] && ui_w "Cannot ping gateway $new_gw (may be normal)" && _log "[2] verify: gw-ping-failed (non-fatal)"
    ui_s "Network configured: $new_ip/$new_cidr (old ${CURRENT_IP}/${CURRENT_CIDR} also active)"
    _log "[2] verify: ok"
    _wstate "STEP_NETWORK=done"; _wstate "STEP_NETWORK_IP_CHANGED=yes"
    _wstate "STEP_NETWORK_NEW_IP=$new_ip"; _wstate "STEP_NETWORK_OLD_IP=${CURRENT_IP}"
    _wstate "STEP_NETWORK_IFACE=$CURRENT_IFACE"; _wstate "STEP_NETWORK_NEW_CIDR=$new_cidr"
    _wstate "STEP_NETWORK_NEW_GW=$new_gw"; _wstate "STEP_NETWORK_NEW_DNS=$new_dns"
    _wstate "STEP_NETWORK_BACKUP=$NETPLAN_BACKUP"
    local uname=$(whoami 2>/dev/null || echo root)
    echo ""; echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║         SETUP PAUSED — NETWORK CHANGED                   ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""; echo "  Your server IP has changed. To continue:"; echo ""
    echo "  1. Open a new terminal/PuTTY/PowerShell:"; echo ""
    echo "     ssh $uname@${new_ip}"; echo ""
    echo "  2. Resume setup:"; echo ""
    echo "     sudo bash $INSTALLER_PATH --resume"; echo ""
    ui_div
    echo "  Done:      System prep, Network (IP: ${new_ip})"
    echo "  Left:      Tailscale, Firewall, DNS, Notacontainer, Homepage"
    ui_div
    echo ""; echo "  OLD IP (${CURRENT_IP}/${CURRENT_CIDR}) still active — reconnect if needed."
    echo "  Will be removed at end of setup."; echo ""
    _log "[2] PAUSE: IP changed — awaiting reconnect"
    exit 2
}

# ── Step 3: Tailscale ───────────────────────────────────────────────────────
step_tailscale() {
    ui_h "STEP 3 — TAILSCALE"
    local choice
    if [ "${INSTALL_TYPE:-custom}" != "quick" ]; then
        choice=$(_ac "Install Tailscale?" "Yes — install and connect" "No — skip" "Install but don't connect yet")
    else
        choice="No — skip"
    fi
    case "$choice" in
        *"Yes — install and connect"*|*"Yes"*)
            ui_st progress "Installing Tailscale"
            if command -v tailscale >/dev/null 2>&1; then
                ui_s "Tailscale: already installed"; _log "[3] tailscale: already-installed"
            else
                if curl -fsSL https://tailscale.com/install.sh | sh -s -- --unattended >/dev/null 2>&1; then
                    ui_s "Tailscale installed"; _log "[3] tailscale: installed"
                else
                    ui_w "Tailscale install failed — skipping"; _log "[3] tailscale: install-failed"
                    _wstate "STEP_TAILSCALE=skipped"; _mkdone "tailscale"; return 0
                fi
            fi
            local authkey=$(_at "Tailscale auth key (blank to configure later)" "")
            if [ -n "$authkey" ]; then
                ui_st progress "Connecting to tailnet"
                if tailscale up --authkey="$authkey" >/dev/null 2>&1; then
                    ui_s "Tailscale: connected"; _log "[3] tailscale-up: connected"; _wstate "STEP_TAILSCALE=connected"
                else
                    ui_w "Tailscale connection failed — run 'tailscale up' manually"; _log "[3] tailscale-up: failed"
                    _wstate "STEP_TAILSCALE=installed-not-connected"
                fi
            else
                ui_i "Tailscale installed — run 'tailscale up' to connect"; _log "[3] tailscale-up: skipped (no key)"
                _wstate "STEP_TAILSCALE=installed-not-connected"
            fi
            _mkdone "tailscale" ;;
        *"Install but don't connect"*|*"Install but don't"*)
            ui_st progress "Installing Tailscale (not connecting)"
            if command -v tailscale >/dev/null 2>&1; then ui_s "Tailscale: already installed"; _log "[3] tailscale: already-installed"
            else
                if curl -fsSL https://tailscale.com/install.sh | sh -s -- --unattended >/dev/null 2>&1; then
                    ui_s "Tailscale installed (not connected)"; _log "[3] tailscale: installed"
                else ui_w "Tailscale install failed"; _log "[3] tailscale: install-failed"; fi
            fi
            _wstate "STEP_TAILSCALE=installed-not-connected"; _mkdone "tailscale" ;;
        *) ui_i "Tailscale: skipped"; _log "[3] tailscale: skipped"
           _wstate "STEP_TAILSCALE=skipped"; _mkdone "tailscale" ;;
    esac
}

# ── Step 4: Firewall ────────────────────────────────────────────────────────
step_firewall() {
    ui_h "STEP 4 — FIREWALL"
    if ! _ay "Configure firewall (UFW)?" "yes"; then
        ui_i "Firewall: skipped"; _log "[4] firewall: skipped"
        _wstate "STEP_FIREWALL=skipped"; _mkdone "firewall"; return 0
    fi
    ui_st progress "Configuring UFW"
    if ! command -v ufw >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || true; _log "[4] ufw-install: done"
    fi
    ufw allow ssh >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
    echo "allow 22/tcp" >> "$UFW_RULES_FILE"; _log "[4] ufw-allow: ssh"; ui_s "SSH allowed"
    local net_choice
    if [ "${INSTALL_TYPE:-custom}" != "quick" ]; then
        net_choice=$(_ac "Which networks can reach the server?" \
            "Tailscale only — only tailnet devices" \
            "LAN only — only local network" \
            "Both — tailscale + LAN" \
            "Custom — specify CIDR ranges")
    else
        net_choice="Both — tailscale + LAN"
    fi
    case "$net_choice" in
        *"Tailscale only"*)
            { [ "${STEP_TAILSCALE:-}" = "connected" ] || [ "${STEP_TAILSCALE:-}" = "installed-not-connected" ]; } && ufw allow from 100.64.0.0/10 >/dev/null 2>&1 && echo "allow 100.64.0.0/10 (tailscale)" >> "$UFW_RULES_FILE" && _log "[4] ufw-allow: 100.64.0.0/10"
            ui_i "UFW: Tailscale only — SSH and tailnet allowed" ;;
        *"LAN only"*)
            local lan_cidr=$(ip -o -4 addr show "$CURRENT_IFACE" 2>/dev/null | grep -v secondary | head -1 | awk '{print $4}')
            [ -n "$lan_cidr" ] && ufw allow from "$lan_cidr" >/dev/null 2>&1 && echo "allow $lan_cidr (lan)" >> "$UFW_RULES_FILE" && _log "[4] ufw-allow: $lan_cidr (lan)"
            ui_i "UFW: LAN only — SSH and LAN allowed" ;;
        *"Both"*)
            [ -n "$CURRENT_CIDR" ] && ufw allow from "192.168.0.0/$CURRENT_CIDR" >/dev/null 2>&1 && echo "allow 192.168.0.0/$CURRENT_CIDR (lan+tailscale)" >> "$UFW_RULES_FILE" && _log "[4] ufw-allow: lan+tailscale"
            ui_i "UFW: Both — SSH, LAN and tailnet allowed" ;;
        *"Custom"*)
            ui_i "Enter CIDR ranges (empty line to finish):"
            while true; do
                local c=$(_at "  CIDR (empty to finish)" "")
                [ -z "$c" ] && break
                ufw allow from "$c" >/dev/null 2>&1 && echo "allow $c (custom)" >> "$UFW_RULES_FILE" && _log "[4] ufw-allow: $c (custom)" && ui_s "Added: $c"
            done ;;
    esac
    echo y | ufw enable >/dev/null 2>&1 || true; _log "[4] ufw-enable: done"
    ui_s "Firewall configured"
    _wstate "STEP_FIREWALL=done"; _mkdone "firewall"
}

step_dns() {
    ui_h "STEP 5 — DNS SERVER"
    if ! _ay "Install a DNS server for *.notaserver?" "yes"; then
        ui_i "DNS server: skipped — you handle DNS yourself"
        _log "[5] dns: skipped"
        _wstate "STEP_DNS=skipped"; _mkdone "dns"; return 0
    fi
    ui_st progress "Installing dnsmasq"
    if ! command -v dnsmasq >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq >/dev/null 2>&1 || { ui_e "dnsmasq install failed"; _log "[5] dnsmasq-install: failed"; _wstate "STEP_DNS=failed"; _mkdone "dns"; return 0; }
        _log "[5] dnsmasq-install: done"
    fi
    ui_s "dnsmasq installed"
    mkdir -p "$DNS_CONF_DIR"
    local server_ip="${STEP_NETWORK_NEW_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    [ -z "$server_ip" ] && server_ip="$CURRENT_IP"
    cat > "$DNS_CONF_FILE" << DNSCONF
# NotaServer DNS: resolves *.notaserver for LAN clients.
# Upstream DNS remains the router.

no-daemon
no-hosts
no-resolv
bind-interfaces
interface=$CURRENT_IFACE
listen-address=127.0.0.1
listen-address=$server_ip
port=53
address=/notaserver/$server_ip
server=$CURRENT_DNS
cache-size=1000
domain-needed
bogus-priv
DNSCONF
    _log "[5] dnsmasq-config: $DNS_CONF_FILE"
    cat > "$SYSTEMD_DNS_UNIT" << UNITSVC
[Unit]
Description=NotaServer lightweight DNS for *.notaserver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --conf-file=$DNS_CONF_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNITSVC
    _log "[5] dns-systemd-unit: $SYSTEMD_DNS_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable notaserver-dns >/dev/null 2>&1 || true
    systemctl restart notaserver-dns >/dev/null 2>&1 || true
    _log "[5] dns-service: enabled+restarted"
    sleep 1
    if systemctl is-active --quiet notaserver-dns 2>/dev/null; then
        ui_s "DNS server: running — *.notaserver resolves to $server_ip"
    else
        ui_w "DNS service not active — check: journalctl -u notaserver-dns -e"
    fi
    _wstate "STEP_DNS=done"; _mkdone "dns"
}

step_server() {
    ui_h "STEP 6 — NOTACONTAINER + HOMEPAGE"
    ui_st progress "Creating data directories"
    mkdir -p "$DATA_ROOT" "$CERTS_DIR" "$CONF_DIR" "$HTML_DIR" "$LOGS_DIR" "$SITES_DIR"
    _log "[6] dirs-created"
    ui_s "Directories created"
    ui_st progress "Pulling homepage"
    if curl -fSL --max-time 60 -o "$HTML_DIR/index.html" "$HOMEPAGE_SOURCE" 2>/dev/null; then
        ui_s "Homepage downloaded ($(wc -c < "$HTML_DIR/index.html") bytes)"; _log "[6] homepage: downloaded"
    else
        ui_w "Could not download homepage — using placeholder"
        echo '<!DOCTYPE html><html><head><title>NotaServer</title><style>body{font-family:system-ui;max-width:800px;margin:40px auto;padding:20px}h1{color:#333}</style></head><body><h1>NotaServer</h1><p>Server running.</p></body></html>' > "$HTML_DIR/index.html"
        _log "[6] homepage: placeholder"
    fi
    ui_st progress "Generating self-signed certificate"
    if [ ! -f "$CERTS_DIR/server.crt" ] || [ ! -f "$CERTS_DIR/server.key" ]; then
        openssl req -x509 -nodes -days 825 -newkey rsa:2048 -keyout "$CERTS_DIR/server.key" -out "$CERTS_DIR/server.crt" -subj "/CN=notaserver/O=NotaServer" >/dev/null 2>&1 || ui_w "Cert generation failed"
        chmod 600 "$CERTS_DIR/server.key" 2>/dev/null || true; _log "[6] certs: generated"
    else
        ui_s "Certificate already present"; _log "[6] certs: already-present"
    fi
    ui_st progress "Writing nginx configuration"
    cat > "$CONF_DIR/nginx.conf" << 'NGINXCONF'
user nginx;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
events { worker_connections 1024; multi_accept on; }
http {
    sendfile on; tcp_nopush on; tcp_nodelay on; keepalive_timeout 65;
    types_hash_max_size 2048; client_max_body_size 50M; server_tokens off;
    include /etc/nginx/mime.types; default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    server { listen 80; server_name notaserver *.notaserver; return 301 https://$host$request_uri; }
    server {
        listen 443 ssl http2 default_server; server_name notaserver *.notaserver;
        ssl_certificate /etc/nginx/certs/server.crt;
        ssl_certificate_key /etc/nginx/certs/server.key;
        ssl_protocols TLSv1.2 TLSv1.3; ssl_ciphers HIGH:!aNULL:!MD5; ssl_prefer_server_ciphers on;
        root /var/www/html; index index.html;
        location / { try_files $uri $uri/ /index.html; }
    }
}
NGINXCONF
    _log "[6] nginx-conf: written"
    if docker ps -a --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true; docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true; _log "[6] old-container: removed"; ui_i "Removed old notacontainer"
    fi
    ui_st progress "Pulling $DOCKER_IMAGE"
    if ! docker pull "$DOCKER_IMAGE" >/dev/null 2>&1; then ui_e "Docker pull failed"; _log "[6] docker-pull: FAILED"; exit 1; fi
    ui_s "Docker image pulled"
    ui_st progress "Starting notacontainer"
    if docker run -d --name "$CONTAINER_NAME" --restart always -p 80:80 -p 443:443 -v "$CONF_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$HTML_DIR:/var/www/html:ro" -v "$CERTS_DIR:/etc/nginx/certs:ro" -v "$LOGS_DIR:/var/log/nginx" "$DOCKER_IMAGE" >/dev/null 2>&1; then
        ui_s "notacontainer started"; _log "[6] container-run: ok"
    else
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        if docker run -d --name "$CONTAINER_NAME" --restart always -p 80:80 -p 443:443 -v "$CONF_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$HTML_DIR:/var/www/html:ro" -v "$CERTS_DIR:/etc/nginx/certs:ro" -v "$LOGS_DIR:/var/log/nginx" "$DOCKER_IMAGE" >/dev/null 2>&1; then
            ui_s "notacontainer started (retry)"; _log "[6] container-run: ok (retry)"
        else
            ui_e "Failed to start notacontainer"; _log "[6] container-run: FAILED"; exit 1; fi
    fi
    sleep 2
    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        ui_s "notacontainer: running on ports 80/443"
    else
        ui_w "notacontainer: not running — check: docker logs $CONTAINER_NAME"
    fi
    _wstate "STEP_SERVER=done"; _mkdone "server"
}

do_cleanup() {
    ui_h "CLEANUP"
    if [ "${STEP_NETWORK_IP_CHANGED:-no}" = "yes" ]; then
        local new_ip="${STEP_NETWORK_NEW_IP:-}"; local iface="${STEP_NETWORK_IFACE:-}"; local cidr="${STEP_NETWORK_NEW_CIDR:-24}"
        if [ -n "$new_ip" ] && [ -n "$iface" ]; then
            ui_st progress "Removing old IP, keeping only $new_ip/$cidr"
            cat > "$NETPLAN_FILE" << NETPLAN2
network:
  version: 2
  renderer: networkd
  ethernets:
    $iface:
      dhcp4: no
      addresses:
        - ${new_ip}/${cidr}
      routes:
        - to: default
          via: ${STEP_NETWORK_NEW_GW:-192.168.0.1}
      nameservers:
        addresses:
          - ${STEP_NETWORK_NEW_DNS:-192.168.0.1}
NETPLAN2
            netplan apply >/dev/null 2>&1 || true; _log "[END] old-ip-removed"; ui_s "Network: $new_ip/$cidr only"
        fi
    fi
    rm -f "$STATE_FILE" "$ROLLBACK_LOG" "$UFW_RULES_FILE" "$NETPLAN_BACKUP"; rm -rf "$SETUP_DIR"
    _log "[END] temp-files: cleaned"
}

show_summary() {
    ui_h "SETUP COMPLETE"
    local hosturl="https://$(hostname -f 2>/dev/null || hostname)"
    echo ""; ui_s "NotaServer is running"; echo ""
    echo "  Homepage:   $hosturl"
    echo "  Notacontainer: running (nginx on ports 80/443)"
    [ "${STEP_NETWORK_IP_CHANGED:-no}" = "yes" ] && echo "  Server IP:  ${STEP_NETWORK_NEW_IP:-unknown}"
    [ "${STEP_TAILSCALE:-skipped}" != "skipped" ] && echo "  Tailscale:  $(command -v tailscale >/dev/null 2>&1 && (tailscale status 2>/dev/null | grep -q connected && echo 'connected' || echo 'installed') || echo 'n/a')"
    [ "${STEP_DNS:-skipped}" != "skipped" ] && echo "  DNS:        dnsmasq — *.notaserver → this server"
    echo ""; ui_div; ui_i "Next steps:"; echo "  • Point browser to $hosturl"; echo "  • Add addons later with installer"; echo "  • Check status: sudo bash $INSTALLER_PATH --status"; echo ""
}

show_menu() {
    ui_h "NOTASERVER SETUP"
    ui_div; echo "  Installation type:"; echo ""
    echo "    1. Full setup — everything, step by step"
    echo "    2. Quick setup — skip network questions, just notacontainer + homepage"
    echo "    3. Custom — answer every question"; echo ""; ui_div
    local choice=$(_rmc 3)
    case "$choice" in 1) INSTALL_TYPE="full" ;; 2) INSTALL_TYPE="quick" ;; 3) INSTALL_TYPE="custom" ;; esac
    export INSTALL_TYPE; echo ""; ui_i "Running in: $INSTALL_TYPE mode"; echo ""
}

run_full_install() { step_system; step_network; step_tailscale; step_firewall; step_dns; step_server; do_cleanup; show_summary; }

do_resume() { _init_dir; _lstate; ui_h "RESUMING SETUP"; ui_i "Resuming from where we left off..."; echo ""
    for step in system network tailscale firewall dns server; do
        if _isdone "$step"; then ui_s "Already done: $step — skipping"
        else case "$step" in system) step_system ;; network) step_network ;; tailscale) step_tailscale ;; firewall) step_firewall ;; dns) step_dns ;; server) step_server ;; esac; fi
    done
    do_cleanup; show_summary
}

main() {
    _ckroot
    if [ "${1:-}" = "--resume" ]; then do_resume; exit 0; fi
    if [ "${1:-}" = "--status" ] || [ "${1:-}" = "--check" ]; then ui_i "Status check (doctor not built yet)"; exit 0; fi
    if [ "${1:-}" = "--rollback" ]; then ui_i "Rollback (not built yet)"; exit 0; fi
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: sudo bash installer.sh [OPTIONS]"; echo ""; echo "Options:"; echo "  (none)     Run interactive setup"; echo "  --resume   Continue paused setup (after IP change)"; echo "  --status   Check setup status"; echo "  --rollback Undo setup steps"; echo "  --help     Show help"; exit 0; fi
    _ckubuntu; _cknet; _init_dir; show_menu; run_full_install
}

main "$@"
