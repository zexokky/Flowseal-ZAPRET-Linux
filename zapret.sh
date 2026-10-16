#!/usr/bin/env bash
# zapret-discord-youtube for Linux (Kali / Debian).
# DPI bypass manager: runs nfqws + nftables NFQUEUE.
#
# Usage:
#   sudo ./zapret.sh                       interactive menu
#   sudo ./zapret.sh start [strategy]      start a strategy in the background (default: general)
#   sudo ./zapret.sh stop                  stop it and remove firewall rules
#   sudo ./zapret.sh restart [strategy]
#   sudo ./zapret.sh status
#   ./zapret.sh list                       list strategies
#   sudo ./zapret.sh install-service <s>   run a strategy at boot (systemd)
#   sudo ./zapret.sh remove-service
#   sudo ./zapret.sh test                  try strategies against utils/targets.txt
#   sudo ./zapret.sh diagnostics
#   sudo ./zapret.sh run <strategy>        foreground mode (used by systemd)

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BIN="$ROOT/bin"
LISTS="$ROOT/lists"
UTILS="$ROOT/utils"
STRATEGIES="$ROOT/strategies"
NFQWS="$BIN/nfqws"

QNUM=200
FWMARK=0x40000000
NFT_TABLE=zapret_dy
SERVICE_NAME=zapret-discord-youtube
SERVICE_FILE=/etc/systemd/system/$SERVICE_NAME.service
PIDFILE=/run/$SERVICE_NAME.pid
STATEFILE=/run/$SERVICE_NAME.strategy

GAME_FLAG_FILE="$UTILS/game_filter.enabled"
IPSET_FILE="$LISTS/ipset-all.txt"
IPSET_BACKUP="$LISTS/ipset-all.txt.backup"
IPSET_NONE="203.0.113.113/32"

REPO_RAW="https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main"
HOSTS_MARK_BEGIN="# >>> zapret-discord-youtube >>>"
HOSTS_MARK_END="# <<< zapret-discord-youtube <<<"

# ---------- output helpers ----------
c_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
c_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die()      { c_red "Error: $*" >&2; exit 1; }
pause()    { [[ -t 0 ]] && read -rp "Press Enter to continue..." _; }

need_root() {
    [[ $EUID -eq 0 ]] || die "root privileges required. Run: sudo $0 ${*:-}"
}

need_nfqws() {
    [[ -x "$NFQWS" ]] || die "nfqws not found at $NFQWS. Run: sudo ./install.sh"
    command -v nft >/dev/null || die "nft not found. Install: sudo apt install nftables"
}

local_version() { tr -d '\r\n ' < "$ROOT/.service/version.txt" 2>/dev/null || echo unknown; }

# ---------- user lists (load_user_lists) ----------
load_user_lists() {
    [[ -f "$LISTS/ipset-exclude-user.txt" ]] || echo "$IPSET_NONE" > "$LISTS/ipset-exclude-user.txt"
    [[ -f "$LISTS/list-general-user.txt" ]] || printf '# Never leave this file empty\ndomain.example.abc\n' > "$LISTS/list-general-user.txt"
    [[ -f "$LISTS/list-exclude-user.txt" ]] || echo "domain.example.abc" > "$LISTS/list-exclude-user.txt"
}

# ---------- game filter ----------
validate_ports() {
    local v="${1// /}" item a b
    [[ -n "$v" ]] || return 1
    IFS=',' read -ra items <<< "$v"
    for item in "${items[@]}"; do
        [[ "$item" =~ ^([1-9][0-9]*)(-([1-9][0-9]*))?$ ]] || return 1
        a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[3]:-$a}
        (( a <= 65535 && b <= 65535 && a <= b )) || return 1
    done
    echo "$v"
}

load_game_filter() {
    GAME_MODE=disabled
    GAME_TCP_RANGE=1024-65535
    GAME_UDP_RANGE=1024-65535
    if [[ -f "$GAME_FLAG_FILE" ]]; then
        local k v r
        while IFS='=' read -r k v; do
            k="${k//[$'\r ']/}"; v="${v//[$'\r ']/}"
            case "${k,,}" in
                mode) GAME_MODE="${v,,}" ;;
                all)  GAME_MODE=all ;;
                tcp)  if [[ -z "$v" ]]; then GAME_MODE=tcp; elif r=$(validate_ports "$v"); then GAME_TCP_RANGE=$r; fi ;;
                udp)  if [[ -z "$v" ]]; then GAME_MODE=udp; elif r=$(validate_ports "$v"); then GAME_UDP_RANGE=$r; fi ;;
            esac
        done < "$GAME_FLAG_FILE"
    fi
    # Port 12 is a harmless placeholder used when the filter is off
    GAME_TCP=12; GAME_UDP=12
    case "$GAME_MODE" in
        all) GAME_TCP=$GAME_TCP_RANGE; GAME_UDP=$GAME_UDP_RANGE; GAME_STATUS="enabled (TCP and UDP)" ;;
        tcp) GAME_TCP=$GAME_TCP_RANGE; GAME_STATUS="enabled (TCP)" ;;
        udp) GAME_UDP=$GAME_UDP_RANGE; GAME_STATUS="enabled (UDP)" ;;
        *)   GAME_MODE=disabled; GAME_STATUS=disabled ;;
    esac
}

save_game_filter() {
    printf 'mode=%s\ntcp=%s\nudp=%s\n' "$GAME_MODE" "$GAME_TCP_RANGE" "$GAME_UDP_RANGE" > "$GAME_FLAG_FILE"
}

# ---------- strategies ----------
strategy_files() { ls -1 "$STRATEGIES"/*.conf 2>/dev/null | sort -V; }

strategy_display_name() {
    sed -n 's/^# name: //p' "$1" | head -1
}

# Accepts: number from list, slug (general-alt2), "general (ALT2)", path
resolve_strategy() {
    local s="${1:-general}" f
    s="${s%.conf}"
    if [[ "$s" =~ ^[0-9]+$ ]]; then
        f=$(strategy_files | sed -n "${s}p")
        [[ -n "$f" ]] && { echo "$f"; return 0; }
    fi
    [[ -f "$s" ]] && { readlink -f "$s"; return 0; }
    [[ -f "$s.conf" ]] && { readlink -f "$s.conf"; return 0; }
    [[ -f "$STRATEGIES/$s.conf" ]] && { echo "$STRATEGIES/$s.conf"; return 0; }
    local slug="${s,,}"; slug="${slug//[()]/}"; slug=$(echo "$slug" | tr -s ' ' '-')
    [[ -f "$STRATEGIES/$slug.conf" ]] && { echo "$STRATEGIES/$slug.conf"; return 0; }
    return 1
}

list_strategies() {
    local i=0 f
    while read -r f; do
        i=$((i + 1))
        printf '  %2d. %-28s %s\n' "$i" "$(basename "$f" .conf)" "$(strategy_display_name "$f")"
    done < <(strategy_files)
}

# Fills NFQWS_ARGS, TCP_PORTS, UDP_PORTS from a strategy file
build_args() {
    local conf="$1" line
    load_game_filter
    # nfqws drops file-access capabilities after start, so it runs as the owner of this
    # folder: otherwise lists inside a private home directory (chmod 700) can't be read
    NFQWS_ARGS=(--qnum="$QNUM" --uid="$(stat -c '%u:%g' "$ROOT")" --dpi-desync-fwmark="$FWMARK")
    TCP_PORTS=""; UDP_PORTS=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line//@BIN@/$BIN}"
        line="${line//@LISTS@/$LISTS}"
        line="${line//@GAME_TCP@/$GAME_TCP}"
        line="${line//@GAME_UDP@/$GAME_UDP}"
        case "$line" in
            TCP_PORTS=*) TCP_PORTS="${line#TCP_PORTS=}" ;;
            UDP_PORTS=*) UDP_PORTS="${line#UDP_PORTS=}" ;;
            *) NFQWS_ARGS+=("$line") ;;
        esac
    done < "$conf"
}

# ---------- firewall ----------
firewall_up() {
    firewall_down
    modprobe nfnetlink_queue 2>/dev/null || true
    sysctl -qw net.ipv4.tcp_timestamps=1 2>/dev/null || true

    local rules="" p
    IFS=',' read -ra tcp <<< "$TCP_PORTS"
    IFS=',' read -ra udp <<< "$UDP_PORTS"
    # One rule per port item: overlapping ranges (game filter 1024-65535 vs 8443) are fine this way
    for p in "${tcp[@]}"; do
        [[ -n "$p" ]] && rules+="        tcp dport $p ct original packets 1-12 queue flags bypass to $QNUM"$'\n'
    done
    for p in "${udp[@]}"; do
        [[ -n "$p" ]] && rules+="        udp dport $p ct original packets 1-12 queue flags bypass to $QNUM"$'\n'
    done

    nft -f - <<EOF
table inet $NFT_TABLE {
    chain postnat {
        type filter hook postrouting priority 101; policy accept;
        meta mark & $FWMARK != 0 return
$rules    }
    chain predefrag {
        type filter hook output priority -401; policy accept;
        meta mark & $FWMARK != 0 notrack
    }
}
EOF
}

firewall_down() {
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
}

# ---------- start / stop ----------
is_running() {
    [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && return 0
    pgrep -x nfqws >/dev/null 2>&1
}

service_active() { systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; }

cmd_start() {
    need_root start; need_nfqws
    local conf
    conf=$(resolve_strategy "${1:-general}") || die "strategy '${1:-}' not found. See: $0 list"
    if service_active; then
        c_yellow "The systemd service is running; stopping it for this manual run."
        systemctl stop "$SERVICE_NAME"
    fi
    cmd_stop quiet
    load_user_lists
    build_args "$conf"
    firewall_up || die "failed to apply nftables rules"
    if ! "$NFQWS" --daemon --pidfile="$PIDFILE" "${NFQWS_ARGS[@]}"; then
        firewall_down
        die "nfqws failed to start (check the strategy arguments above)"
    fi
    basename "$conf" .conf > "$STATEFILE"
    c_green "zapret started: $(strategy_display_name "$conf") [$(basename "$conf" .conf)]"
    echo "Game filter: $GAME_STATUS"
}

cmd_stop() {
    need_root stop
    if [[ -f "$PIDFILE" ]]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    # Only kill nfqws instances started from this folder
    pkill -f "^$NFQWS " 2>/dev/null || true
    firewall_down
    rm -f "$STATEFILE"
    [[ "${1:-}" == quiet ]] || c_green "zapret stopped"
}

# Foreground mode for systemd
cmd_run() {
    need_root run; need_nfqws
    local conf
    conf=$(resolve_strategy "${1:-general}") || die "strategy '${1:-}' not found"
    load_user_lists
    build_args "$conf"
    firewall_up || die "failed to apply nftables rules"
    basename "$conf" .conf > "$STATEFILE"
    trap 'firewall_down; rm -f "$STATEFILE"' EXIT
    "$NFQWS" "${NFQWS_ARGS[@]}"
}

cmd_status() {
    local s
    if [[ -f "$SERVICE_FILE" ]]; then
        s=$(sed -n 's/^# strategy: //p' "$SERVICE_FILE")
        echo "Service installed with strategy: $s"
        if service_active; then c_green "Service $SERVICE_NAME is RUNNING"; else c_yellow "Service $SERVICE_NAME is NOT running"; fi
    else
        echo "Service is not installed"
    fi
    if is_running; then
        c_green "Bypass (nfqws) is RUNNING: $(cat "$STATEFILE" 2>/dev/null || echo unknown strategy)"
    else
        c_red "Bypass (nfqws) is NOT running"
    fi
    if [[ $EUID -eq 0 ]]; then
        if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then c_green "nftables rules are loaded"; else c_red "nftables rules are NOT loaded"; fi
    fi
    [[ -x "$NFQWS" ]] || c_red "nfqws binary not found ($NFQWS). Run: sudo ./install.sh"
}

# ---------- systemd service ----------
cmd_install_service() {
    need_root install-service; need_nfqws
    local conf choice slug
    conf=""
    if [[ -n "${1:-}" ]]; then
        conf=$(resolve_strategy "$1") || die "strategy '$1' not found"
    else
        echo "Pick one of the strategies:"; list_strategies; echo
        read -rp "Input strategy number or name: " choice
        conf=$(resolve_strategy "$choice") || { c_red "Invalid choice"; return 1; }
    fi
    slug=$(basename "$conf" .conf)
    cmd_stop quiet
    cat > "$SERVICE_FILE" <<EOF
# strategy: $slug
[Unit]
Description=zapret DPI bypass for Discord and YouTube ($slug)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart="$ROOT/zapret.sh" run $slug
ExecStopPost="$ROOT/zapret.sh" firewall-down
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    sleep 1
    if service_active; then c_green "Service installed and started: $slug"; else c_red "Service failed to start. See: journalctl -u $SERVICE_NAME -e"; fi
}

cmd_remove_service() {
    need_root remove-service
    if [[ -f "$SERVICE_FILE" ]]; then
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        c_green "Service $SERVICE_NAME removed"
    else
        echo "Service $SERVICE_NAME is not installed"
    fi
    cmd_stop quiet
}

# ---------- settings ----------
ipset_status() {
    if [[ ! -s "$IPSET_FILE" ]] || ! grep -q '[^[:space:]]' "$IPSET_FILE"; then echo any
    elif grep -q "$IPSET_NONE" "$IPSET_FILE"; then echo none
    else echo loaded; fi
}

cmd_ipset_switch() {
    case "$(ipset_status)" in
        loaded) echo "Switching to none mode..."; mv -f "$IPSET_FILE" "$IPSET_BACKUP"; echo "$IPSET_NONE" > "$IPSET_FILE" ;;
        none)   echo "Switching to any mode..."; : > "$IPSET_FILE" ;;
        any)
            echo "Switching to loaded mode..."
            if [[ -f "$IPSET_BACKUP" ]]; then mv -f "$IPSET_BACKUP" "$IPSET_FILE"
            else c_red "No backup to restore. Update the list from the menu first"; return 1; fi ;;
    esac
    c_yellow "Restart zapret to apply changes"
}

cmd_game_switch() {
    load_game_filter
    local mark choice v
    echo "Select game filter option:"
    for opt in "1 disabled Disable" "2 all TCP and UDP" "3 tcp TCP" "4 udp UDP"; do
        set -- $opt; mark=" "; [[ "$GAME_MODE" == "$2" ]] && mark="*"
        echo "  $1. $mark ${*:3}"
    done
    echo
    echo "  5. Change TCP port range (current: $GAME_TCP_RANGE)"
    echo "  6. Change UDP port range (current: $GAME_UDP_RANGE)"
    echo "  7. Change TCP and UDP port ranges"
    echo "  0. Exit"
    read -rp "Select option (0-7, default: 0): " choice
    case "${choice:-0}" in
        1) GAME_MODE=disabled ;; 2) GAME_MODE=all ;; 3) GAME_MODE=tcp ;; 4) GAME_MODE=udp ;;
        5|6|7)
            read -rp "Enter ports (e.g. 1024-65535 or 27015,27020-27050): " v
            v=$(validate_ports "$v") || { c_red "Invalid port range"; return 1; }
            [[ $choice != 6 ]] && GAME_TCP_RANGE=$v
            [[ $choice != 5 ]] && GAME_UDP_RANGE=$v ;;
        *) return 0 ;;
    esac
    save_game_filter
    c_yellow "Restart zapret to apply changes"
}

cmd_replace_fakes() {
    local -a files names
    local f i=0 dh gh cur_d="(not found)" cur_g="(not found)" choice type num active
    for f in "$BIN"/*.bin; do
        [[ "$(basename "$f")" == ACTIVE_* ]] && continue
        files+=("$f"); names+=("$(basename "$f" .bin)")
    done
    (( ${#files[@]} )) || { echo "No .bin files were found in the bin folder."; return 1; }
    while true; do
        dh=$(sha256sum "$BIN/ACTIVE_DISCORD_UDP.bin" 2>/dev/null | cut -d' ' -f1)
        gh=$(sha256sum "$BIN/ACTIVE_GAME_UDP.bin" 2>/dev/null | cut -d' ' -f1)
        cur_d="(not found)"; cur_g="(not found)"
        for i in "${!files[@]}"; do
            h=$(sha256sum "${files[$i]}" | cut -d' ' -f1)
            [[ "$h" == "$dh" ]] && cur_d=${names[$i]}
            [[ "$h" == "$gh" ]] && cur_g=${names[$i]}
        done
        echo
        echo "Enter the fake type number and the fake file number to replace it with."
        echo "Example: 1 4 (replaces Discord UDP with fake file number 4)"
        echo "Press Enter or 0 to return."
        echo
        echo "Fake types:"
        echo "  1. Discord UDP     (current: $cur_d)"
        echo "  2. GameFilter UDP  (current: $cur_g)"
        echo
        echo "Fake files:"
        for i in "${!names[@]}"; do echo "  $((i + 1)). ${names[$i]}"; done
        echo
        read -rp "Enter choice: " type num
        [[ -z "$type" || "$type" == 0 ]] && return 0
        case "$type" in
            1) active="$BIN/ACTIVE_DISCORD_UDP.bin" ;;
            2) active="$BIN/ACTIVE_GAME_UDP.bin" ;;
            *) c_red "Invalid fake type."; continue ;;
        esac
        [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#files[@]} )) || { c_red "Invalid fake file number."; continue; }
        if cp -f "${files[$((num - 1))]}" "$active"; then c_green "Active fake file replaced successfully."; else c_red "Failed to replace the active fake file."; fi
    done
}

# ---------- updates ----------
cmd_ipset_update() {
    echo "Updating ipset-all..."
    local tmp; tmp=$(mktemp)
    if curl -fsSL --max-time 20 -o "$tmp" "$REPO_RAW/.service/ipset-service.txt"; then
        sed -i 's/\r$//' "$tmp"
        mv -f "$tmp" "$IPSET_FILE"; chmod 644 "$IPSET_FILE"
        c_green "Finished. Restart zapret to apply changes"
    else
        rm -f "$tmp"; c_red "Download failed"
    fi
}

cmd_hosts_update() {
    need_root update-hosts
    local tmp ans; tmp=$(mktemp)
    if ! curl -fsSL --max-time 20 -o "$tmp" "$REPO_RAW/.service/hosts?t=$RANDOM$RANDOM"; then
        rm -f "$tmp"; c_red "Failed to download hosts file from repository"; return 1
    fi
    sed -i 's/\r$//' "$tmp"
    local first last; first=$(grep -m1 . "$tmp"); last=$(grep . "$tmp" | tail -1)
    if grep -qF "$first" /etc/hosts && grep -qF "$last" /etc/hosts; then
        c_green "Hosts file is up to date"; rm -f "$tmp"; return 0
    fi
    c_yellow "Hosts file needs to be updated ($(grep -c . "$tmp") lines from the repository)."
    read -rp "Write them into /etc/hosts now? A backup is saved to /etc/hosts.zapret.bak [y/N]: " ans
    if [[ "${ans,,}" == y* ]]; then
        cp -f /etc/hosts /etc/hosts.zapret.bak
        sed -i "/^$HOSTS_MARK_BEGIN\$/,/^$HOSTS_MARK_END\$/d" /etc/hosts
        { echo "$HOSTS_MARK_BEGIN"; cat "$tmp"; echo "$HOSTS_MARK_END"; } >> /etc/hosts
        c_green "/etc/hosts updated"
    else
        echo "Skipped. Downloaded file: $tmp"
        return 0
    fi
    rm -f "$tmp"
}

# ---------- diagnostics ----------
cmd_diagnostics() {
    c_green "Zapret is installed in: $ROOT"; echo
    if [[ -x "$NFQWS" ]]; then c_green "nfqws found: $("$NFQWS" --version 2>&1 | head -1)"
    else c_red "[X] nfqws not found. Run: sudo ./install.sh"; fi
    if command -v nft >/dev/null; then c_green "nftables check passed"
    else c_red "[X] nft not found. Install: sudo apt install nftables"; fi
    if modprobe -n nfnetlink_queue 2>/dev/null || lsmod | grep -q nfnetlink_queue; then c_green "nfnetlink_queue kernel module check passed"
    else c_red "[X] nfnetlink_queue kernel module is not available"; fi
    if [[ "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null)" == 1 ]]; then c_green "TCP timestamps check passed"
    else
        c_yellow "[?] TCP timestamps are disabled. Enabling..."
        sysctl -qw net.ipv4.tcp_timestamps=1 && c_green "TCP timestamps enabled" || c_red "[X] Failed to enable TCP timestamps"
    fi
    if [[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}" ]]; then
        c_yellow "[?] A proxy is set in the environment. Make sure it is valid or unset it"
    else c_green "Proxy check passed"; fi
    local other; other=$(pgrep -a 'nfqws|tpws|byedpi|ciadpi|spoofdpi' | grep -v "^$$ " | grep -vF "$NFQWS" || true)
    if [[ -n "$other" ]]; then c_red "[X] Other DPI bypass programs are running and may conflict:"; echo "$other"
    else c_green "Conflicting bypass check passed"; fi
    if systemctl is-active --quiet zapret 2>/dev/null; then c_red "[X] Another 'zapret' systemd service is active and may conflict"; fi
    if ip -o link show 2>/dev/null | grep -qE ': (tun|wg|tap|proton|nordlynx)[^:]*:'; then
        c_yellow "[?] VPN interface detected. A VPN may conflict with zapret"
    else c_green "VPN check passed"; fi
    if nft list ruleset 2>/dev/null | grep -q "queue.* to $QNUM" && ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        c_red "[X] Another nftables rule uses queue $QNUM"
    fi
    if command -v resolvectl >/dev/null && resolvectl status 2>/dev/null | grep -qi 'DNSOverTLS.*yes'; then
        c_green "Secure DNS (DNS over TLS) is enabled"
    else
        c_yellow "[?] Secure DNS is not detected. If sites still fail, configure DoH in the browser or DoT in systemd-resolved"
    fi
    if grep -qF "$HOSTS_MARK_BEGIN" /etc/hosts 2>/dev/null; then echo "Repository entries are present in /etc/hosts"; fi
    echo
    cmd_status
}

# ---------- tests ----------
cmd_test() {
    need_root test; need_nfqws
    local targets="$UTILS/targets.txt" results_dir="$UTILS/test results" out
    mkdir -p "$results_dir"
    out="$results_dir/test-$(date +%Y%m%d-%H%M%S).txt"
    local -a keys vals confs
    local k v line
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]] || continue
        keys+=("${BASH_REMATCH[1]}"); vals+=("${BASH_REMATCH[2]}")
    done < "$targets"
    (( ${#keys[@]} )) || die "no targets in $targets"

    if [[ -n "${1:-}" ]]; then
        local c; c=$(resolve_strategy "$1") || die "strategy '$1' not found"; confs=("$c")
    else
        mapfile -t confs < <(strategy_files)
    fi

    local was_service=0; service_active && { was_service=1; systemctl stop "$SERVICE_NAME"; }
    echo "Testing ${#confs[@]} strategies against ${#keys[@]} targets. Results: $out"
    local conf ok total i code best="" best_ok=-1
    for conf in "${confs[@]}"; do
        cmd_start "$(basename "$conf" .conf)" >/dev/null || { c_red "$(basename "$conf"): failed to start"; continue; }
        sleep 2
        ok=0; total=0
        echo "=== $(strategy_display_name "$conf")" | tee -a "$out"
        for i in "${!keys[@]}"; do
            k=${keys[$i]}; v=${vals[$i]}; total=$((total + 1))
            if [[ "$v" == PING:* ]]; then
                if ping -c 1 -W 2 "${v#PING:}" >/dev/null 2>&1; then code=OK; ok=$((ok + 1)); else code=FAIL; fi
            else
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -r 0-65535 "$v" 2>/dev/null)
                if [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]; then ok=$((ok + 1)); code="OK ($code)"; else code="FAIL"; fi
            fi
            printf '  %-24s %s\n' "$k" "$code" | tee -a "$out"
        done
        printf '  result: %d/%d\n' "$ok" "$total" | tee -a "$out"
        (( ok > best_ok )) && { best_ok=$ok; best=$(basename "$conf" .conf); }
        cmd_stop quiet
    done
    echo | tee -a "$out"
    c_green "Best strategy: $best ($best_ok/${#keys[@]})" | tee -a "$out"
    (( was_service )) && systemctl start "$SERVICE_NAME"
}

# ---------- menu ----------
menu() {
    need_root
    load_user_lists
    local choice cur
    while true; do
        clear
        load_game_filter
        cur="(not running)"
        is_running && cur="Running: $(cat "$STATEFILE" 2>/dev/null || echo unknown)"
        cat <<EOF

  ZAPRET SERVICE MANAGER v$(local_version)
  $cur
  ----------------------------------------

  :: RUN
     1. Start strategy (manual)
     2. Stop
  :: SERVICE (systemd, starts at boot)
     3. Install Service
     4. Remove Service
     5. Check Status

  :: SETTINGS
     6. Game Filter         [$GAME_STATUS]
     7. IPSet Filter        [$(ipset_status)]
     8. Replace active fakes

  :: UPDATES
     9. Update IPSet List
     10. Update Hosts File

  :: TOOLS
     11. Run Diagnostics
     12. Run Tests

  ----------------------------------------
     0. Exit

EOF
        read -rp "   Select option (0-12): " choice
        clear
        case "$choice" in
            1) list_strategies; echo; read -rp "Strategy number or name [general]: " s; cmd_start "${s:-general}"; pause ;;
            2) cmd_stop; pause ;;
            3) cmd_install_service; pause ;;
            4) cmd_remove_service; pause ;;
            5) cmd_status; pause ;;
            6) cmd_game_switch; pause ;;
            7) cmd_ipset_switch; pause ;;
            8) cmd_replace_fakes ;;
            9) cmd_ipset_update; pause ;;
            10) cmd_hosts_update; pause ;;
            11) cmd_diagnostics; pause ;;
            12) read -rp "Strategy to test (Enter = all): " s; cmd_test "${s:-}"; pause ;;
            0) exit 0 ;;
        esac
    done
}

case "${1:-menu}" in
    menu)            menu ;;
    start)           cmd_start "${2:-general}" ;;
    stop)            cmd_stop ;;
    restart)         prev=$(cat "$STATEFILE" 2>/dev/null || echo general); cmd_start "${2:-$prev}" ;;
    status)          cmd_status ;;
    list)            list_strategies ;;
    run)             cmd_run "${2:-general}" ;;
    firewall-down)   need_root; firewall_down ;;
    install-service) cmd_install_service "${2:-}" ;;
    remove-service)  cmd_remove_service ;;
    game-filter)     need_root; cmd_game_switch ;;
    ipset-filter)    cmd_ipset_switch ;;
    update-ipset)    cmd_ipset_update ;;
    update-hosts)    cmd_hosts_update ;;
    replace-fakes)   cmd_replace_fakes ;;
    diagnostics)     need_root; cmd_diagnostics ;;
    test)            cmd_test "${2:-}" ;;
    -h|--help|help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)               die "unknown command '$1'. See: $0 help" ;;
esac
