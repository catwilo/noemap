#!/bin/sh
# scan.sh — host discovery + SSH port probe
#
# Exports:
#   HOST_LIST — newline-separated list of live IPs (SSH reachable)
#
# Strategy:
#   noemap is an SSH device mapper, not a general network scanner.
#   Discovery checks only SSH ports (22, 8022, 2222) so every result
#   is a host you can actually connect to.
#
#   Pre-scan validation (Phase 0):
#     Ping all hosts already registered in devices.db.
#     - Responds:    accepted as-is; added to HOST_LIST, skipped in full scan.
#     - No response: removed from devices.db and known_hosts automatically.
#
#   Phase 1 — ARP ping via nmap -sn -PR (fast, L2, no routing needed).
#              Falls back to TCP-SYN ping if ARP fails (non-Ethernet).
#              Already-validated hosts are excluded from this scan.
#
#   Phase 2 — SSH port probe on discovered IPs (nmap -p or nc fallback).
#              Only hosts with at least one SSH port open are kept.
#
# Environment:
#   NOEMAP_FULL_PORTS=1  set by noemap --ports; controls display only
#   NOEMAP_DEEP=1        set by noemap --deep; runs broader phase-1 + phase-2

_SSH_PORTS="22,8022,2222"

# Device database path (also defined in fingerprint.sh; declared here because
# scan.sh is sourced before fingerprint.sh in the module load order).
DEVICES_DB="${DEVICES_DB:-$BASE/state/devices.db}"

# ---------------------------------------------------------------------------
# _nmap_ssh_probe host_file out_file port_list
# ---------------------------------------------------------------------------
_nmap_ssh_probe() {
    _hf="$1"; _of="$2"; _ports="$3"
    nmap \
        -Pn \
        -n \
        --host-timeout 4s \
        -p "$_ports" \
        -iL "$_hf" \
        2>/dev/null \
    > "$_of" || true
}

# ---------------------------------------------------------------------------
# _nc_ssh_probe ip — checks if any SSH port is open via nc.
# Prints the first open port number, or nothing.
# ---------------------------------------------------------------------------
# Connect-timeout flags for nc, resolved once and cached in _NC_CT_FLAGS.
# BSD/macOS nc honours -G (connect timeout) for SYN to a dead host; -w alone
# is ignored there and hangs until the kernel TCP timeout. Linux nc has no -G
# and uses -w. Probe the actual binary instead of assuming.
_nc_connect_flags() {
    if [ -n "${_NC_CT_FLAGS+x}" ]; then
        printf '%s' "$_NC_CT_FLAGS"
        return 0
    fi
    if nc -h 2>&1 | grep -q -- '-G'; then
        _NC_CT_FLAGS='-G 2 -w 2'
    else
        _NC_CT_FLAGS='-w 2'
    fi
    printf '%s' "$_NC_CT_FLAGS"
}
_nc_ssh_probe() {
    _h="$1"
    _ct="$(_nc_connect_flags)"
    for _p in 22 8022 2222; do
        # shellcheck disable=SC2086
        if nc -z $_ct "$_h" "$_p" >/dev/null 2>&1; then
            printf '%s\n' "$_p"
            return 0
        fi
    done
}

# ---------------------------------------------------------------------------
# _ping_host ip — returns 0 if host responds to ping, 1 otherwise.
# Uses a single packet with 1-second timeout.
# ---------------------------------------------------------------------------
_ping_host() {
    ping -c 1 -W 1 "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _validate_registered_hosts — Phase 0.
#
# Pings every host in devices.db:
#   - Responds  → added to _validated_tmp (accepted, skip full scan)
#   - No response → removed from devices.db and known_hosts
#
# Writes validated IPs to the file path in $1.
# Sets _SKIP_IPS to a newline-separated list of already-validated IPs.
# ---------------------------------------------------------------------------
_validate_registered_hosts() {
    _vout="$1"
    : > "$_vout"
    _SKIP_IPS=""

    [ -f "$DEVICES_DB" ] && [ -s "$DEVICES_DB" ] || return 0

    log INFO "validating registered hosts..."

    # Collect all registered IPs into a temp list
    _reg_tmp="$(session_tmp reg_ips)"
    awk -F'|' '
        /^[[:space:]]*$/ { next }
        /^#/             { next }
        NF >= 2          { print $2 }
    ' "$DEVICES_DB" 2>/dev/null > "$_reg_tmp"

    [ -s "$_reg_tmp" ] || return 0

    while IFS= read -r _rip; do
        [ -n "$_rip" ] || continue
        [ "$_rip" = "$MY_IP" ] && continue   # never remove self

        if _ping_host "$_rip"; then
            log INFO "registered host $_rip: online — accepted"
            printf '%s\n' "$_rip" >> "$_vout"
        else
            log WARN "registered host $_rip: no response — removing from devices.db and known_hosts"
            _remove_offline_host "$_rip"
        fi
    done < "$_reg_tmp"

    if [ -s "$_vout" ]; then
        _SKIP_IPS="$(cat "$_vout")"
    fi
}

# ---------------------------------------------------------------------------
# _remove_offline_host ip — removes a non-responding host from devices.db
# and cleans its known_hosts entries.
# ---------------------------------------------------------------------------
_remove_offline_host() {
    _off_ip="$1"

    # Find alias for logging
    _off_alias="$(awk -F'|' -v ip="$_off_ip" '
        /^[[:space:]]*$/ { next }
        /^#/             { next }
        $2 == ip         { print $1; exit }
    ' "$DEVICES_DB" 2>/dev/null)"

    _off_tmp="$(mktemp "${TMPDIR:-/tmp}/noemap.XXXXXX")"
    awk -F'|' -v ip="$_off_ip" '
        /^[[:space:]]*$/ { print; next }
        /^#/             { print; next }
        $2 == ip         { next }
        { print }
    ' "$DEVICES_DB" > "$_off_tmp" && mv -f "$_off_tmp" "$DEVICES_DB" || rm -f "$_off_tmp"

    known_hosts_remove_ip "$_off_ip"

    if [ -n "$_off_alias" ]; then
        log OK "removed offline host '$_off_alias' ($_off_ip) from all lists"
    else
        log OK "removed offline host $_off_ip from all lists"
    fi
}

# ---------------------------------------------------------------------------
# discover_hosts — main entry point. Sets HOST_LIST.
# ---------------------------------------------------------------------------
discover_hosts() {
    log INFO "discovering hosts on $SUBNET"

    _arp_tmp="$(session_tmp arp_out)"
    _ssh_tmp="$(session_tmp ssh_out)"
    _nmap_port_out="$(session_tmp nmap_ports)"
    _validated_tmp="$(session_tmp validated_hosts)"

    # -------------------------------------------------------------------
    # Phase 0: validate already-registered hosts via ping
    # Hosts that respond are accepted immediately; non-responding hosts
    # are purged from devices.db and known_hosts.
    # -------------------------------------------------------------------
    _SKIP_IPS=""
    _validate_registered_hosts "$_validated_tmp"

    # -------------------------------------------------------------------
    # Phase 1: discover new hosts — ARP ping (or TCP-SYN fallback).
    # Exclude already-validated IPs to avoid redundant work.
    # -------------------------------------------------------------------
    if has_cmd nmap; then
        nmap -sn -PR -n --host-timeout 3s "$SUBNET" 2>/dev/null \
            | awk '/Nmap scan report/ {ip=$NF} /Host is up/ {print ip}' \
            > "$_arp_tmp" || true

        if [ ! -s "$_arp_tmp" ]; then
            log INFO "ARP ping returned nothing — trying TCP-SYN ping"
            nmap -sn -PS22,8022,2222,80 -n --host-timeout 3s "$SUBNET" 2>/dev/null \
                | awk '/Nmap scan report/ {ip=$NF} /Host is up/ {print ip}' \
                > "$_arp_tmp" || true
        fi
    else
        log WARN "nmap not found — falling back to nc probe (SSH ports only)"
        _base="$(printf '%s\n' "$MY_IP" | cut -d. -f1-3)"
        _nc_tmp="$(session_tmp nc_tmp)"
        : > "$_nc_tmp"
        _jobs=0; _max=16; _i=1
        while [ "$_i" -le 254 ]; do
            _tip="${_base}.${_i}"
            ( _nc_ssh_probe "$_tip" >/dev/null && printf '%s\n' "$_tip" >> "$_nc_tmp" ) &
            _jobs=$(( _jobs + 1 ))
            [ "$_jobs" -lt "$_max" ] || { wait; _jobs=0; }
            _i=$(( _i + 1 ))
        done
        wait
        if [ -s "$_nc_tmp" ]; then
            sort -t. -k4 -n "$_nc_tmp" > "$_arp_tmp" || true
        fi
    fi

    # Remove self and already-validated IPs from the discovery list
    if [ -s "$_arp_tmp" ]; then
        _arp_filtered="$(session_tmp arp_filtered)"
        : > "$_arp_filtered"
        while IFS= read -r _candidate; do
            [ -n "$_candidate" ]      || continue
            [ "$_candidate" = "$MY_IP" ] && continue

            # Skip if already validated via Phase 0
            _skip=0
            for _vip in $_SKIP_IPS; do
                [ "$_vip" = "$_candidate" ] && { _skip=1; break; }
            done
            [ "$_skip" -eq 1 ] && continue

            printf '%s\n' "$_candidate" >> "$_arp_filtered"
        done < "$_arp_tmp"
        mv -f "$_arp_filtered" "$_arp_tmp"
    fi

    if [ ! -s "$_arp_tmp" ] && [ ! -s "$_validated_tmp" ]; then
        log INFO "no live hosts found on $SUBNET"
        HOST_LIST=""
        return 0
    fi

    if [ -s "$_arp_tmp" ]; then
        _live_count="$(wc -l < "$_arp_tmp" | tr -d ' ')"
        log INFO "phase 1: $_live_count new candidate(s) to probe"
    fi

    # -------------------------------------------------------------------
    # Phase 2: SSH port probe on new candidates only
    # -------------------------------------------------------------------
    : > "$_ssh_tmp"

    if [ -s "$_arp_tmp" ]; then
        if has_cmd nmap; then
            _nmap_ssh_probe "$_arp_tmp" "$_nmap_port_out" "$_SSH_PORTS"

            awk '
                /Nmap scan report for / { cur_ip = $NF; has_open = 0 }
                /open/                  { has_open = 1 }
                /Nmap scan report for / && NR > 1 && prev_has_open { print prev_ip }
                END { if (has_open) print cur_ip }
                { prev_ip = cur_ip; prev_has_open = has_open }
            ' "$_nmap_port_out" > "$_ssh_tmp" || true

            # Fallback parser if above yields nothing but nmap ran fine
            if [ ! -s "$_ssh_tmp" ] && [ -s "$_nmap_port_out" ]; then
                awk '
                    /Nmap scan report for / { ip = $NF; open=0 }
                    /\/tcp.*open/           { open=1 }
                    /Nmap scan report for / && NR>1 && prev_open { print prev_ip }
                    END                     { if (open) print ip }
                    { prev_ip=ip; prev_open=open }
                ' "$_nmap_port_out" > "$_ssh_tmp" || true
            fi
        else
            while IFS= read -r _ip; do
                ( _p="$(_nc_ssh_probe "$_ip")"
                  [ -n "$_p" ] && printf '%s\n' "$_ip" >> "$_ssh_tmp" ) &
            done < "$_arp_tmp"
            wait
            if [ -s "$_ssh_tmp" ]; then
                sort -t. -k4 -n "$_ssh_tmp" > "${_ssh_tmp}.s" \
                    && mv -f "${_ssh_tmp}.s" "$_ssh_tmp" || true
            fi
        fi
    fi

    # Deep scan mode (--deep): broader discovery before fingerprinting
    if [ "${NOEMAP_DEEP:-0}" = "1" ]; then
        log INFO "deep scan requested — running broader discovery..."

        _deep_tmp="$(session_tmp deep_out)"
        _deep_ports="$(session_tmp deep_ports)"

        if has_cmd nmap; then
            nmap -sn -PR -PS22,8022,2222,80 -n "$SUBNET" 2>/dev/null \
                | awk '/Nmap scan report/ {ip=$NF} /Host is up/ {print ip}' \
                > "$_deep_tmp" || true

            if [ -s "$_deep_tmp" ]; then
                _nmap_ssh_probe "$_deep_tmp" "$_deep_ports" "$_SSH_PORTS"
                awk '
                    /Nmap scan report for / { cur_ip=$NF; has_open=0 }
                    /open/                  { has_open=1 }
                    /Nmap scan report for / && NR>1 && prev_open { print prev_ip }
                    END { if (has_open) print cur_ip }
                    { prev_ip=cur_ip; prev_open=has_open }
                ' "$_deep_ports" > "$_ssh_tmp" || true
            fi
        else
            : > "$_ssh_tmp"
            _base="$(printf '%s\n' "$MY_IP" | cut -d. -f1-3)"
            _nc_d="$(session_tmp nc_deep)"
            : > "$_nc_d"
            _j=0; _m=24; _i=1
            while [ "$_i" -le 254 ]; do
                _tip="${_base}.${_i}"
                ( _p="$(_nc_ssh_probe "$_tip")"
                  [ -n "$_p" ] && printf '%s\n' "$_tip" >> "$_nc_d" ) &
                _j=$(( _j + 1 ))
                [ "$_j" -lt "$_m" ] || { wait; _j=0; }
                _i=$(( _i + 1 ))
            done
            wait
            if [ -s "$_nc_d" ]; then
                sort -t. -k4 -n "$_nc_d" > "$_ssh_tmp" || true
            fi
        fi

        # Exclude self after deep scan
        if [ -s "$_ssh_tmp" ]; then
            _no_self2="$(session_tmp ssh_no_self2)"
            grep -v "^${MY_IP}$" "$_ssh_tmp" > "$_no_self2" 2>/dev/null || true
            mv -f "$_no_self2" "$_ssh_tmp"
        fi

        _ssh_count="$(wc -l < "$_ssh_tmp" 2>/dev/null | tr -d ' ')"
        log INFO "deep scan: ${_ssh_count:-0} SSH-reachable host(s)"
    fi

    # -------------------------------------------------------------------
    # Merge: validated (Phase 0) + new SSH-reachable (Phase 2)
    # -------------------------------------------------------------------
    _merged="$(session_tmp merged_hosts)"
    : > "$_merged"

    # Add Phase 0 validated hosts
    if [ -s "$_validated_tmp" ]; then
        cat "$_validated_tmp" >> "$_merged"
    fi

    # Add Phase 2 new hosts (exclude self and already-validated)
    if [ -s "$_ssh_tmp" ]; then
        while IFS= read -r _ip; do
            [ -n "$_ip" ]          || continue
            [ "$_ip" = "$MY_IP" ] && continue
            _skip=0
            for _vip in $_SKIP_IPS; do
                [ "$_vip" = "$_ip" ] && { _skip=1; break; }
            done
            [ "$_skip" -eq 1 ] && continue
            printf '%s\n' "$_ip" >> "$_merged"
        done < "$_ssh_tmp"
    fi

    if [ ! -s "$_merged" ]; then
        log INFO "no SSH-reachable hosts found"
        HOST_LIST=""
        return 0
    fi

    # Sort and deduplicate
    sort -t. -k4 -n "$_merged" | sort -u > "${_merged}.s" \
        && mv -f "${_merged}.s" "$_merged" || true

    _total="$(wc -l < "$_merged" | tr -d ' ')"
    log INFO "total: ${_total:-0} SSH-reachable host(s) (includes validated registered)"

    HOST_LIST="$(cat "$_merged")"
}
