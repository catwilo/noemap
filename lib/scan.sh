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

    _reg_aliases="$(session_tmp reg_aliases)"
    awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$DEVICES_DB" > "$_reg_aliases" 2>/dev/null

    _reg_tmp="$(session_tmp reg_ips)"
    : > "$_reg_tmp"
    while IFS= read -r _ralias; do
        [ -n "$_ralias" ] || continue
        _rblk="$(blockdb_get "$DEVICES_DB" alias "$_ralias")"
        [ -n "$_rblk" ] || continue
        _rip="$(blockdb_field "$_rblk" ip)"
        [ -n "$_rip" ] && printf '%s\n' "$_rip" >> "$_reg_tmp"
    done < "$_reg_aliases"

    [ -s "$_reg_tmp" ] || return 0

    _STALE_ALIAS_CANDIDATES=""

    while IFS= read -r _rip; do
        [ -n "$_rip" ] || continue
        [ "$_rip" = "$MY_IP" ] && continue   # never remove self

        case "$_rip" in
            100.*)
                log INFO "registered host $_rip: tailscale ip -- accepted (no ping)"
                printf '%s\n' "$_rip" >> "$_vout"
                continue
                ;;
        esac

        if _ping_host "$_rip"; then
            log INFO "registered host $_rip: online — accepted"
            printf '%s\n' "$_rip" >> "$_vout"
        else
            _stale_blk="$(blockdb_get "$DEVICES_DB" ip "$_rip")"
            _stale_alias="$([ -n "$_stale_blk" ] && blockdb_field "$_stale_blk" alias || printf '')"
            if [ -n "$_stale_alias" ]; then
                _STALE_ALIAS_CANDIDATES="$_STALE_ALIAS_CANDIDATES $_stale_alias"
                log WARN "registered host $_rip (alias '$_stale_alias'): no response -- candidate for IP-change detection this run (not purged yet)"
            else
                log WARN "registered host $_rip: no response — removing from devices.db and known_hosts"
                _remove_offline_host "$_rip"
            fi
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

    _off_blk="$(blockdb_get "$DEVICES_DB" ip "$_off_ip")"
    _off_alias="$([ -n "$_off_blk" ] && blockdb_field "$_off_blk" alias || printf '')"

    [ -n "$_off_alias" ] && blockdb_remove "$DEVICES_DB" alias "$_off_alias"

    known_hosts_remove_ip "$_off_ip"

    if [ -n "$_off_alias" ]; then
        log OK "removed offline host '$_off_alias' ($_off_ip) from all lists"
    else
        log OK "removed offline host $_off_ip from all lists"
    fi
}

# ---------------------------------------------------------------------------
# _self_register — #17: ensure this node's own IP is in devices.db so peers
# that receive the distributed db know how to reach back. Uses hostname as
# alias and the current user; port 8022 (Termux/Android sshd default). No-op
# if MY_IP is already present. Safe to call repeatedly (idempotent).
# ---------------------------------------------------------------------------
_registry_pull_latest() {
    _rpl_dir="$HOME/.noemap-registry"
    [ -d "$_rpl_dir/.git" ] || return 0
    ( cd "$_rpl_dir" && git pull --rebase origin main >/dev/null 2>&1 ) || true
}

_self_register() {
    [ -n "${MY_IP:-}" ] || return 0
    [ -f "$DEVICES_DB" ] || : > "$DEVICES_DB"

    # Session-level idempotency guard (noemap#500): _self_register is called
    # twice per run (discover_hosts + sync_devices_to_nodes). Without this,
    # each call reaches _registry_write unconditionally, causing two full
    # git checkout+push+merge cycles in a single noemap run.
    [ -z "${_SELF_REGISTER_DONE:-}" ] || return 0

    _registry_pull_latest

    _self_alias=""
    _self_user=""
    _self_port=""
    _self_platform=""
    if command -v node_registry_row >/dev/null 2>&1; then
        _self_row="$(node_registry_row 2>/dev/null)"
        if [ -n "$_self_row" ]; then
            _self_alias="$(blockdb_field "$_self_row" alias)"
            _self_user="$(blockdb_field "$_self_row" user)"
            _self_port="$(blockdb_field "$_self_row" port)"
            _self_platform="$(blockdb_field "$_self_row" platform)"
            _self_alias_from_registry=1
        fi
    fi

    if [ -z "$_self_alias" ] && command -v _node_config_load >/dev/null 2>&1; then
        _self_cache_row="$(_node_config_load 2>/dev/null)"
        if [ -n "$_self_cache_row" ]; then
            _self_alias="$(printf '%s\n' "$_self_cache_row" | cut -d'|' -f1)"
            _self_user="$(printf '%s\n'  "$_self_cache_row" | cut -d'|' -f2)"
            _self_port="$(printf '%s\n'  "$_self_cache_row" | cut -d'|' -f3)"
            log INFO "identity resolved from local node-config cache (registry unreachable): $_self_alias"
        fi
    fi

    if [ "${_self_alias_from_registry:-0}" = "1" ]; then
        _self_own_nid="$(node_id)"
        _self_by_nid="$(blockdb_get "$DEVICES_DB" node_id "$_self_own_nid")"
        if [ -n "$_self_by_nid" ]; then
            _self_stale_alias="$(blockdb_field "$_self_by_nid" alias)"
            if [ -n "$_self_stale_alias" ] && [ "$_self_stale_alias" != "$_self_alias" ]; then
                log WARN "devices.db had stale self alias '$_self_stale_alias' (registry.db says '$_self_alias') -- correcting"
                blockdb_remove "$DEVICES_DB" alias "$_self_stale_alias"
            fi
        fi
    fi

    if [ -z "$_self_alias" ]; then
        _self_prompt_rc=1
        if command -v _prompt_self_identity >/dev/null 2>&1; then
            _self_alias="$(_prompt_self_identity)"; _self_prompt_rc=$?
        fi
        if [ -z "$_self_alias" ]; then
            if [ "$_self_prompt_rc" -eq 1 ] && [ ! -t 1 ]; then
                log WARN "this node has no canonical identity -- non-interactive context (no TTY), run: ndevs --node-set <alias>"
            else
                log WARN "this node has no canonical identity -- run: ndevs --node-set <alias>"
            fi
            _SELF_REGISTER_DONE=1
            return 0
        fi
        _self_user=""
        _self_port=""
    fi

    _self_user="${_self_user:-$(id -un 2>/dev/null || whoami 2>/dev/null || printf 'u')}"
    _self_port="${_self_port:-8022}"
    _self_platform="${_self_platform:-android}"

    _self_prev_hk=""
    _self_blk_by_alias="$(blockdb_get "$DEVICES_DB" alias "$_self_alias")"
    if [ -n "$_self_blk_by_alias" ]; then
        _self_prev_hk="$(blockdb_field "$_self_blk_by_alias" hostkey)"
    fi
    _self_blk_by_ip="$(blockdb_get "$DEVICES_DB" ip "$MY_IP")"
    if [ -z "$_self_prev_hk" ] && [ -n "$_self_blk_by_ip" ]; then
        _self_prev_hk="$(blockdb_field "$_self_blk_by_ip" hostkey)"
    fi

    # Dedup by IP first (covers stale alias pointing at same IP under a
    # different name), then upsert by alias with the fresh block.
    if [ -n "$_self_blk_by_ip" ] && [ "$(blockdb_field "$_self_blk_by_ip" alias)" != "$_self_alias" ]; then
        blockdb_remove "$DEVICES_DB" ip "$MY_IP"
    fi

    _self_block="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\nnode_id: %s\n' \
        "$_self_alias" "$MY_IP" "$_self_user" "$_self_port" "$_self_platform" "${_self_prev_hk:-}" "$(node_id)")"
    blockdb_upsert "$DEVICES_DB" alias "$_self_alias" "$_self_block"
    log OK "self-registered $_self_alias ($MY_IP) platform=$_self_platform in devices.db"
    if command -v node_alias_set >/dev/null 2>&1; then
        node_alias_set "$_self_alias" "$_self_user" "$_self_port" "$_self_platform" || \
            log WARN "node_alias_set failed -- registry.db not updated this run (see error above)"
    fi
    if command -v _node_config_save >/dev/null 2>&1; then
        _node_config_save "$_self_alias" "$_self_user" "$_self_port" || \
            log WARN "_node_config_save failed -- local offline cache not updated this run"
    fi
    _SELF_REGISTER_DONE=1
}

# ---------------------------------------------------------------------------
# sync_devices_to_nodes — #16: after a successful scan, push the full
# devices.db to every registered node (skipping self) so all nodes share one
# source of truth without running noemap locally. Best-effort: a node that is
# down is warned, never fatal. Calls _self_register first (#17) so the
# distributed db always includes this node.
# ---------------------------------------------------------------------------
sync_devices_to_nodes() {
    # Internal/automated call -- never prompt for a password mid-scan;
    # fail fast instead (ssh_config's automation Match block enforces
    # BatchMode yes once nssh receives this, per bin/nssh's fix in a745bf1
    # to preserve a caller-set role instead of overwriting it).
    export NOEMAP_SSH_ROLE=automation

    _self_register

    [ -f "$DEVICES_DB" ] && [ -s "$DEVICES_DB" ] || return 0
    has_cmd nssh || { log WARN "nssh not found -- skipping device sync"; return 0; }

    _remote_db="$HOME/.local/share/noemap/state/devices.db"
    _sdn_aliases="$(session_tmp sdn_aliases)"
    awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$DEVICES_DB" > "$_sdn_aliases" 2>/dev/null

    _sdn_tmp="$(session_tmp sdn_pairs)"
    : > "$_sdn_tmp"
    while IFS= read -r _sdn_alias; do
        [ -n "$_sdn_alias" ] || continue
        _sdn_blk="$(blockdb_get "$DEVICES_DB" alias "$_sdn_alias")"
        [ -n "$_sdn_blk" ] || continue
        _sdn_ip="$(blockdb_field "$_sdn_blk" ip)"
        [ -n "$_sdn_ip" ] && printf '%s|%s\n' "$_sdn_alias" "$_sdn_ip" >> "$_sdn_tmp"
    done < "$_sdn_aliases"

    while IFS='|' read -r _sa _sip <&3; do
        [ -n "$_sa" ] || continue
        [ "$_sip" = "${MY_IP:-}" ] && continue   # never push to self
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_sip"; then continue; fi
        if nssh "$_sa" "mkdir -p ~/.local/share/noemap/state && cat > ~/.local/share/noemap/state/devices.db" < "$DEVICES_DB"; then
            log OK "synced devices.db -> $_sa"
        else
            log WARN "sync to $_sa failed (node down?) -- skipped"
        fi
    done 3< "$_sdn_tmp"
}

# ---------------------------------------------------------------------------
# _purge_unrescued_stale_aliases -- call AFTER fingerprint_hosts(). Any alias
# in _STALE_ALIAS_CANDIDATES that was NOT rescued (moved to a new IP) by
# _update_registered_hosts' hostkey match still points at a dead IP -- purge
# it now (miko-task#294 fix, second half: candidates not silently kept
# forever if no matching new host showed up this run).
# ---------------------------------------------------------------------------
_purge_unrescued_stale_aliases() {
    [ -n "${_STALE_ALIAS_CANDIDATES:-}" ] || return 0
    for _cand in $_STALE_ALIAS_CANDIDATES; do
        _cand_blk="$(blockdb_get "$DEVICES_DB" alias "$_cand")"
        [ -n "$_cand_blk" ] || continue
        _cand_ip="$(blockdb_field "$_cand_blk" ip)"
        [ -n "$_cand_ip" ] || continue
        if _ping_host "$_cand_ip"; then
            continue  # rescued in place or still reachable somehow -- leave it
        fi
        log WARN "stale alias '$_cand' not rescued by hostkey match -- purging ($_cand_ip unreachable)"
        _remove_offline_host "$_cand_ip"
    done
}
# ---------------------------------------------------------------------------
# _seed_from_registry — pull every OTHER node's row from the cloud registry
# (REGISTRY_DB) into local devices.db, so a node that has never been LAN-
# discovered yet (e.g. just registered via --node-add on a different
# machine) still shows up in `ndevs` on this node. Never touches this
# node's own row (that is _self_register's job, called separately).
# IP is left blank if devices.db has none yet -- the LAN scan phases that
# follow in discover_hosts() fill it in when the peer is actually reachable.
# Best-effort, idempotent: skipped entirely if REGISTRY_DB is absent.
# ---------------------------------------------------------------------------
_seed_from_registry() {
    [ -f "$REGISTRY_DB" ] || return 0
    [ -f "$DEVICES_DB" ] || : > "$DEVICES_DB"

    _sfr_own_nid="$(node_id)"
    _sfr_nids="$(session_tmp sfr_nids)"
    awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "node_id") { print substr($i, colon + 2); break }
            }
        }
    ' "$REGISTRY_DB" > "$_sfr_nids" 2>/dev/null

    while IFS= read -r _sfr_nid; do
        [ -n "$_sfr_nid" ] || continue
        [ "$_sfr_nid" = "$_sfr_own_nid" ] && continue

        _sfr_reg_blk="$(blockdb_get "$REGISTRY_DB" node_id "$_sfr_nid")"
        [ -n "$_sfr_reg_blk" ] || continue
        _sfr_alias="$(blockdb_field "$_sfr_reg_blk" alias)"
        [ -n "$_sfr_alias" ] || continue

        _sfr_existing="$(blockdb_get "$DEVICES_DB" node_id "$_sfr_nid")"
        [ -n "$_sfr_existing" ] && continue

        _sfr_user="$(blockdb_field "$_sfr_reg_blk" user)"
        _sfr_port="$(blockdb_field "$_sfr_reg_blk" port)"
        _sfr_platform="$(blockdb_field "$_sfr_reg_blk" platform)"
        _sfr_hk="$(blockdb_field "$_sfr_reg_blk" hostkey)"
        [ -n "$_sfr_user" ] || _sfr_user="u"
        [ -n "$_sfr_port" ] || _sfr_port=8022
        [ -n "$_sfr_platform" ] || _sfr_platform="android"

        _sfr_block="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nplatform: %s\nhostkey: %s\nnode_id: %s\n' \
            "$_sfr_alias" "" "$_sfr_user" "$_sfr_port" "$_sfr_platform" "${_sfr_hk:-}" "$_sfr_nid")"
        blockdb_upsert "$DEVICES_DB" alias "$_sfr_alias" "$_sfr_block"
        log OK "seeded '$_sfr_alias' from cloud registry (node $_sfr_nid, ip pending discovery)"
    done < "$_sfr_nids"
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

    _SKIP_IPS=""
    _self_register
    _seed_from_registry
    _validate_registered_hosts "$_validated_tmp"

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

    if [ -s "$_arp_tmp" ]; then
        _arp_filtered="$(session_tmp arp_filtered)"
        : > "$_arp_filtered"
        while IFS= read -r _candidate; do
            [ -n "$_candidate" ]      || continue
            [ "$_candidate" = "$MY_IP" ] && continue

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

        if [ -s "$_ssh_tmp" ]; then
            _no_self2="$(session_tmp ssh_no_self2)"
            grep -v "^${MY_IP}$" "$_ssh_tmp" > "$_no_self2" 2>/dev/null || true
            mv -f "$_no_self2" "$_ssh_tmp"
        fi

        _ssh_count="$(wc -l < "$_ssh_tmp" 2>/dev/null | tr -d ' ')"
        log INFO "deep scan: ${_ssh_count:-0} SSH-reachable host(s)"
    fi

    _merged="$(session_tmp merged_hosts)"
    : > "$_merged"

    if [ -s "$_validated_tmp" ]; then
        cat "$_validated_tmp" >> "$_merged"
    fi

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

    sort -t. -k4 -n "$_merged" | sort -u > "${_merged}.s" \
        && mv -f "${_merged}.s" "$_merged" || true

    _total="$(wc -l < "$_merged" | tr -d ' ')"
    log INFO "total: ${_total:-0} SSH-reachable host(s) (includes validated registered)"

    HOST_LIST="$(cat "$_merged")"
}
