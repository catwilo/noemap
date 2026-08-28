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
            _alias="$(awk -F'|' -v ip="$_ip" '
                /^[[:space:]]*$/{ next } /^#/{ next }
                $2==ip{ print $1; exit }
            ' "$_devdb" 2>/dev/null)"
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

    [ -f "$_devdb" ] || return 0
    awk -F'|' '/^[[:space:]]*$/{next}/^#/{next}NF>=2{found=1;exit}END{exit !found}' \
        "$_devdb" 2>/dev/null || return 0

    printf "${_C_BOLD}${_C_CYAN}  REGISTERED DEVICES${_C_RESET}\n\n"

    # build rows + compute dynamic column widths in one awk pass
    _rows_tmp="$(mktemp "${TMPDIR:-/tmp}/noemap-rows.XXXXXX")"
    awk -F'|' -v hdb="${_hosts_db:-}" '
        /^[[:space:]]*$/{next}/^#/{next}NF<2{next}
        {
            alias=$1; ip=$2; user=($3==""?"?":$3); port=($4==""?"22":$4)
            os="-"
            if(hdb!="" && (getline ln < "/dev/null") >= 0) {
                while((getline ln < hdb)>0) {
                    split(ln,a,"|"); if(a[1]==ip){os=a[2];break}
                }
                close(hdb)
            }
            rows[NR]=alias "|" ip "|" port "|" user "|" os
            if(length(alias)>w1) w1=length(alias)
            if(length(ip)>w2)    w2=length(ip)
            if(length(port)>w3)  w3=length(port)
            if(length(user)>w4)  w4=length(user)
            if(length(os)>w5)    w5=length(os)
            n=NR
        }
        END {
            w1=(w1>5?w1:5); w2=(w2>2?w2:2); w3=(w3>4?w3:4); w4=(w4>4?w4:4); w5=(w5>2?w5:2)
            print w1 " " w2 " " w3 " " w4 " " w5
            for(i=1;i<=n;i++) if(i in rows) print rows[i]
        }
    ' "$_devdb" > "$_rows_tmp"

    read -r _w1 _w2 _w3 _w4 _w5 < "$_rows_tmp"
    _d1="$(printf '%*s' "$_w1" | tr ' ' '-')"
    _d2="$(printf '%*s' "$_w2" | tr ' ' '-')"
    _d3="$(printf '%*s' "$_w3" | tr ' ' '-')"
    _d4="$(printf '%*s' "$_w4" | tr ' ' '-')"
    _d5="$(printf '%*s' "$_w5" | tr ' ' '-')"
    printf "  ${_C_BOLD}%-${_w1}s  %-${_w2}s  %-${_w3}s  %-${_w4}s  %s${_C_RESET}\n" \
        "ALIAS" "IP" "PORT" "USER" "OS"
    printf "  %s  %s  %s  %s  %s\n" "$_d1" "$_d2" "$_d3" "$_d4" "$_d5"

    tail -n +2 "$_rows_tmp" | while IFS='|' read -r _a _i _p _u _o; do
        [ -n "$_a" ] || continue
        _c_os="${_C_RESET}"
        case "$_o" in
            mac)          _c_os="${_C_CYAN}"  ;;
            android-ssh)  _c_os="${_C_GREEN}" ;;
            linux*|unix*) _c_os="${_C_BOLD}"  ;;
        esac
        printf "  ${_C_GREEN}%-${_w1}s${_C_RESET}  ${_C_CYAN}%-${_w2}s${_C_RESET}  ${_C_YELLOW}%-${_w3}s${_C_RESET}  %-${_w4}s  ${_c_os}%s${_C_RESET}\n" \
            "$_a" "$_i" "$_p" "$_u" "$_o"
    done
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
    [ -f "$_devdb" ] || return 0
    awk -F'|' '/^[[:space:]]*$/{next}/^#/{next}NF>=2{found=1;exit}END{exit !found}' \
        "$_devdb" 2>/dev/null || return 0

    _ex="$(awk -F'|' '/^[[:space:]]*$/{next}/^#/{next}NF>=2{print $1;exit}' \
        "$_devdb" 2>/dev/null)"
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
        _found="$(awk -F'|' -v ip="$_ip" '
            /^[[:space:]]*$/{ next } /^#/{ next }
            $2==ip{ print 1; exit }
        ' "$_devdb" 2>/dev/null)"
        [ -z "$_found" ] && printf '%s|%s|%s\n' \
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
        while awk -F'|' -v a="$_default_alias" '
            /^[[:space:]]*$/{next}/^#/{next}
            $1==a{found=1;exit}END{exit !found}
        ' "$_devdb" 2>/dev/null; do
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

        _alias_cur_ip="$(awk -F'|' -v a="$_alias" '
            /^[[:space:]]*$/{ next } /^#/{ next }
            $1==a{ print $2; exit }
        ' "$_devdb" 2>/dev/null)"

        if [ -n "$_alias_cur_ip" ] && [ "$_alias_cur_ip" != "$_ip" ]; then
            printf "  ${_C_CYAN}[i]${_C_RESET} \"%s\" existed (%s) -- IP updated to %s\n" \
                "$_alias" "$_alias_cur_ip" "$_ip"
            known_hosts_remove_ip "$_alias_cur_ip"
            _tmp_db="$(mktemp "${TMPDIR:-/tmp}/ndevs.XXXXXX")"
            awk -F'|' -v a="$_alias" -v ni="$_ip" -v np="${_ssh_port:-22}" '
                /^[[:space:]]*$/{print;next}/^#/{print;next}
                $1==a{ printf "%s|%s|%s|%s|%s\n",$1,ni,$3,np,$5; next }{ print }
            ' "$_devdb" > "$_tmp_db"
            mv -f "$_tmp_db" "$_devdb"
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
        _tmp_db="$(mktemp "${TMPDIR:-/tmp}/ndevs.XXXXXX")"
        { cat "$_devdb"
          printf '%s|%s|%s|%s|%s\n' "$_alias" "$_ip" "$_reg_user" "${_ssh_port:-22}" "${_new_host_hk:-}"
        } > "$_tmp_db"

        if awk -F'|' '/^[[:space:]]*$/{next}/^#/{next}NF<2{exit 1}' "$_tmp_db"; then
            mv -f "$_tmp_db" "$_devdb"
            printf "  ${_C_GREEN}[OK]${_C_RESET} registered \"%s\" -> %s  user=%s  port=%s\n\n" \
                "$_alias" "$_ip" "$_reg_user" "${_ssh_port:-22}"
        else
            rm -f "$_tmp_db"
            printf "  ${_C_YELLOW}[!]${_C_RESET} validation failed for \"%s\" -- skipped\n\n" "$_alias"
        fi
    done < "$_new_tmp"
    rm -f "$_new_tmp"
}
