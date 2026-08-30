#!/bin/sh
# output.sh — render discovery results and drive post-display registration

# ── color setup ───────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _C_RESET='\033[0m'
    _C_CYAN='\033[0;36m'
    _C_GREEN='\033[0;32m'
    _C_YELLOW='\033[1;33m'
    _C_BOLD='\033[1m'
    _C_DIM='\033[2m'
else
    _C_RESET='' _C_CYAN='' _C_GREEN='' _C_YELLOW='' _C_BOLD='' _C_DIM=''
fi

_pad() { printf '%*s' "$1" '' | tr ' ' '-'; }

_hdr() {
    printf "${_C_BOLD}${_C_CYAN}  %-16s  %-14s  %-10s  %-6s  %s${_C_RESET}\n" \
        "IP" "OS" "ALIAS" "PORT" "TTL"
    printf "  %s  %s  %s  %s  %s\n" \
        "$(_pad 16)" "$(_pad 14)" "$(_pad 10)" "$(_pad 6)" "$(_pad 3)"
}

render_output() {
    _hosts_db="$BASE/state/hosts.db"
    _devdb="$BASE/state/devices.db"

    printf '\n'
    printf "${_C_BOLD}  NET   ${_C_RESET}%s\n" "${SUBNET:-?}"
    printf "${_C_BOLD}  GW    ${_C_RESET}%s\n" "${GW_IP:-?}"
    printf '\n'

    if [ ! -f "$_hosts_db" ] || [ ! -s "$_hosts_db" ]; then
        printf '  No hosts found.\n\n'
        return 0
    fi

    _n="$(wc -l < "$_hosts_db" | tr -d ' ')"
    printf "${_C_BOLD}  %s host(s) discovered${_C_RESET}\n\n" "$_n"
}

render_active_hosts() {
    _hosts_db="$BASE/state/hosts.db"
    _devdb="$BASE/state/devices.db"

    [ -f "$_hosts_db" ] && [ -s "$_hosts_db" ] || return 0

    printf "${_C_BOLD}${_C_CYAN}  ACTIVE HOSTS${_C_RESET}\n\n"
    _hdr

    while IFS='|' read -r _ip _type _ttl _ssh_port _all_ports; do
        [ -n "$_ip" ] || continue
        _alias=""
        if [ -f "$_devdb" ]; then
            _alias_blk="$(blockdb_get "$_devdb" ip "$_ip")"
            [ -n "$_alias_blk" ] && _alias="$(blockdb_field "$_alias_blk" alias)"
        fi
        _port_disp="${_ssh_port:-?}"
        [ "$_port_disp" = "0" ] && _port_disp="-"
        printf "  ${_C_GREEN}%-16s${_C_RESET}  %-14s  %-10s  %-6s  %s\n" \
            "$_ip" "${_type:-?}" "${_alias:--}" "$_port_disp" "${_ttl:-?}"
        if [ "${NOEMAP_FULL_PORTS:-0}" = "1" ] && [ -n "$_all_ports" ]; then
            printf "  %16s  ${_C_DIM}ports: %s${_C_RESET}\n" "" "$_all_ports"
        fi
    done < "$_hosts_db"
    printf '\n'
}

render_registered_devices() {
    _devdb="$BASE/state/devices.db"
    _hosts_db="$BASE/state/hosts.db"

    [ -f "$_devdb" ] && [ -s "$_devdb" ] || return 0

    printf "${_C_BOLD}${_C_CYAN}  REGISTERED DEVICES${_C_RESET}\n\n"

    # build rows + compute dynamic column widths
    _rows_tmp="$(mktemp "${TMPDIR:-/tmp}/noemap-rows.XXXXXX")"
    _n=0
    _w1=5; _w2=2; _w3=4; _w4=4; _w5=2
    _rrd_aliases="$(blockdb_list "$_devdb" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ')"
    printf '%s\n' "$_rrd_aliases" | while IFS= read -r _rrd_alias; do
        [ -n "$_rrd_alias" ] || continue
        _rrd_blk="$(blockdb_get "$_devdb" alias "$_rrd_alias")"
        [ -n "$_rrd_blk" ] || continue
        _rrd_ip="$(blockdb_field "$_rrd_blk" ip)"
        _rrd_user="$(blockdb_field "$_rrd_blk" user)"; _rrd_user="${_rrd_user:-?}"
        _rrd_port="$(blockdb_field "$_rrd_blk" port)"; _rrd_port="${_rrd_port:-22}"
        _rrd_os="-"
        if [ -f "$_hosts_db" ]; then
            _rrd_os_line="$(awk -F'|' -v ip="$_rrd_ip" '$1==ip{print $2; exit}' "$_hosts_db" 2>/dev/null)"
            [ -n "$_rrd_os_line" ] && _rrd_os="$_rrd_os_line"
        fi
        printf '%s|%s|%s|%s|%s\n' "$_rrd_alias" "$_rrd_ip" "$_rrd_port" "$_rrd_user" "$_rrd_os" >> "$_rows_tmp"
    done

    [ -s "$_rows_tmp" ] || { rm -f "$_rows_tmp"; return 0; }

    while IFS='|' read -r _a _i _p _u _o; do
        [ -n "$_a" ] || continue
        [ "${#_a}" -gt "$_w1" ] && _w1="${#_a}"
        [ "${#_i}" -gt "$_w2" ] && _w2="${#_i}"
        [ "${#_p}" -gt "$_w3" ] && _w3="${#_p}"
        [ "${#_u}" -gt "$_w4" ] && _w4="${#_u}"
        [ "${#_o}" -gt "$_w5" ] && _w5="${#_o}"
    done < "$_rows_tmp"

    _d1="$(printf '%*s' "$_w1" | tr ' ' '-')"
    _d2="$(printf '%*s' "$_w2" | tr ' ' '-')"
    _d3="$(printf '%*s' "$_w3" | tr ' ' '-')"
    _d4="$(printf '%*s' "$_w4" | tr ' ' '-')"
    _d5="$(printf '%*s' "$_w5" | tr ' ' '-')"
    printf "  ${_C_BOLD}%-${_w1}s  %-${_w2}s  %-${_w3}s  %-${_w4}s  %s${_C_RESET}\n" \
        "ALIAS" "IP" "PORT" "USER" "OS"
    printf "  %s  %s  %s  %s  %s\n" "$_d1" "$_d2" "$_d3" "$_d4" "$_d5"

    while IFS='|' read -r _a _i _p _u _o; do
        [ -n "$_a" ] || continue
        _c_os="${_C_RESET}"
        case "$_o" in
            mac)          _c_os="${_C_CYAN}"  ;;
            android-ssh)  _c_os="${_C_GREEN}" ;;
            linux*|unix*) _c_os="${_C_BOLD}"  ;;
        esac
        printf "  ${_C_GREEN}%-${_w1}s${_C_RESET}  ${_C_CYAN}%-${_w2}s${_C_RESET}  ${_C_YELLOW}%-${_w3}s${_C_RESET}  %-${_w4}s  ${_c_os}%s${_C_RESET}\n" \
            "$_a" "$_i" "$_p" "$_u" "$_o"
    done < "$_rows_tmp"
    rm -f "$_rows_tmp"
    printf '\n'

    _local_alias=""
    if command -v node_alias >/dev/null 2>&1; then
        _local_alias="$(node_alias 2>/dev/null)"
    fi
    if [ -z "$_local_alias" ] && command -v _node_config_load >/dev/null 2>&1; then
        _local_cache_row="$(_node_config_load 2>/dev/null)"
        [ -n "$_local_cache_row" ] && _local_alias="$(printf '%s\n' "$_local_cache_row" | cut -d'|' -f1)"
    fi
    printf "  Local node: ${_C_GREEN}%s${_C_RESET}  ${_C_DIM}(%s [%s])${_C_RESET}\n\n" \
        "${_local_alias:-unknown}" "${MY_IP:-?}" "${PRIMARY_IFACE:-?}"
}

render_connect() {
    _devdb="$BASE/state/devices.db"
    [ -f "$_devdb" ] && [ -s "$_devdb" ] || return 0

    _rc_aliases="$(blockdb_list "$_devdb" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); exit }
            }
        }
    ')"
    _ex="$(printf '%s\n' "$_rc_aliases" | head -1)"
    _ex="${_ex:-<alias>}"

    printf "${_C_BOLD}${_C_CYAN}  CONNECT${_C_RESET}  ${_C_DIM}(replace %s with any alias)${_C_RESET}\n\n" "$_ex"
    printf "  %-12s  %s\n" "shell"      "nssh $_ex"
    printf "  %-12s  %s\n" "cmd"        "nssh $_ex uname -a"
    printf "  %-12s  %s\n" "copy from"  "nscp $_ex:/remote/path ./"
    printf "  %-12s  %s\n" "copy to"    "nscp ./file $_ex:/remote/"
    printf "  %-12s  %s\n" "clipboard"  "nclip $_ex:/remote/file"
    printf '\n'
}

# ---------------------------------------------------------------------------
# prompt_new_hosts — interactive registration of new hosts
# ---------------------------------------------------------------------------
prompt_new_hosts() {
    [ -t 1 ] || return 0

    _hosts_db="$BASE/state/hosts.db"
    _devdb="$BASE/state/devices.db"

    [ -f "$_hosts_db" ] && [ -s "$_hosts_db" ] || return 0
    [ -f "$_devdb" ] || touch "$_devdb"

    _new_tmp="$(mktemp "${TMPDIR:-/tmp}/noemap.XXXXXX")"
    while IFS='|' read -r _ip _type _ttl _ssh_port _all_ports; do
        [ -n "$_ip" ] || continue
        _found_blk="$(blockdb_get "$_devdb" ip "$_ip")"
        [ -z "$_found_blk" ] && printf '%s|%s|%s\n' \
            "$_ip" "$_type" "${_ssh_port:-22}" >> "$_new_tmp"
    done < "$_hosts_db"

    if [ ! -s "$_new_tmp" ]; then rm -f "$_new_tmp"; return 0; fi

    printf "${_C_BOLD}  -- NEW HOSTS -- press Enter to accept suggestion --${_C_RESET}\n\n"

    while IFS='|' read -r _ip _type _ssh_port; do
        [ -n "$_ip" ] || continue
        printf "  ${_C_YELLOW}%s${_C_RESET}  os=%-14s  port=%s\n" \
            "$_ip" "$_type" "${_ssh_port:-22}"

        case "$_type" in
            android-ssh) _base_alias="tx" ;;
            mac)         _base_alias="mac" ;;
            *)           _base_alias="db" ;;
        esac
        _n=0; _default_alias="$_base_alias"
        while [ -n "$(blockdb_get "$_devdb" alias "$_default_alias")" ]; do
            _n=$(( _n + 1 )); _default_alias="${_base_alias%b}${_n}"
        done

        _alias=""
        while [ -z "$_alias" ]; do
            printf "  Alias [%s]: " "$_default_alias"
            read -r _input_alias </dev/tty || _input_alias=""
            _input_alias="$(printf '%s' "$_input_alias" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -z "$_input_alias" ]; then
                _alias="$_default_alias"
            else
                case "$_input_alias" in
                    *[^a-zA-Z0-9_-]*)
                        printf "  ${_C_YELLOW}[!]${_C_RESET} invalid chars -- only a-z 0-9 _ -\n"
                        continue ;;
                esac
                [ "${#_input_alias}" -gt 20 ] && {
                    printf "  ${_C_YELLOW}[!]${_C_RESET} too long (max 20)\n"; continue; }
                _alias="$_input_alias"
            fi
        done

        _alias_cur_blk="$(blockdb_get "$_devdb" alias "$_alias")"
        _alias_cur_ip="$([ -n "$_alias_cur_blk" ] && blockdb_field "$_alias_cur_blk" ip || printf '')"

        if [ -n "$_alias_cur_ip" ] && [ "$_alias_cur_ip" != "$_ip" ]; then
            printf "  ${_C_CYAN}[i]${_C_RESET} \"%s\" existed (%s) -- IP updated to %s\n" \
                "$_alias" "$_alias_cur_ip" "$_ip"
            known_hosts_remove_ip "$_alias_cur_ip"
            _cur_user="$(blockdb_field "$_alias_cur_blk" user)"
            _cur_hk="$(blockdb_field "$_alias_cur_blk" hostkey)"
            _cur_nid="$(blockdb_field "$_alias_cur_blk" node_id)"
            _new_blk="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' \
                "$_alias" "$_ip" "${_cur_user:-}" "${_ssh_port:-22}" "${_cur_hk:-}" "${_cur_nid:-}")"
            blockdb_upsert "$_devdb" alias "$_alias" "$_new_blk"
            printf '\n'; continue
        fi

        case "$_type" in
            mac) _default_user="pelucainestable" ;;
            *)   _default_user="u" ;;
        esac
        _reg_user=""
        while [ -z "$_reg_user" ]; do
            printf "  User [%s]: " "$_default_user"
            read -r _input_user </dev/tty || _input_user=""
            _input_user="$(printf '%s' "$_input_user" | \
                sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
            [ -z "$_input_user" ] && _reg_user="$_default_user" || _reg_user="$_input_user"
        done

        known_hosts_remove_ip "$_ip"
        _new_host_hk="$(_get_host_key_fingerprint "$_ip" "${_ssh_port:-22}" 2>/dev/null)"
        _new_blk="$(printf 'alias: %s\nip: %s\nuser: %s\nport: %s\nhostkey: %s\nnode_id: %s\n' \
            "$_alias" "$_ip" "$_reg_user" "${_ssh_port:-22}" "${_new_host_hk:-}" "")"
        blockdb_upsert "$_devdb" alias "$_alias" "$_new_blk"
        printf "  ${_C_GREEN}[OK]${_C_RESET} registered \"%s\" -> %s  user=%s  port=%s\n\n" \
            "$_alias" "$_ip" "$_reg_user" "${_ssh_port:-22}"
    done < "$_new_tmp"
    rm -f "$_new_tmp"
}
