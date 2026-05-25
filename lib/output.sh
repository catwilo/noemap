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
    printf "${_C_BOLD}  SELF  ${_C_RESET}%s  ${_C_DIM}[%s]${_C_RESET}\n" \
        "${MY_IP:-?}" "${PRIMARY_IFACE:-?}"
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
    printf "${_C_BOLD}  %-12s  %-16s  %-6s  %-10s  %s${_C_RESET}\n" \
        "ALIAS" "IP" "PORT" "USER" "OS"
    printf "  %s  %s  %s  %s  %s\n" \
        "$(_pad 12)" "$(_pad 16)" "$(_pad 6)" "$(_pad 10)" "$(_pad 12)"

    while IFS='|' read -r _alias _ip _user _port || [ -n "$_alias" ]; do
        case "$_alias" in '#'*|'') continue ;; esac
        [ -n "$_ip" ] || continue
        _port="${_port:-22}"
        _user="${_user:-?}"
        _os="-"
        if [ -f "$_hosts_db" ]; then
            _os="$(awk -F'|' -v ip="$_ip" '
                /^[[:space:]]*$/{ next } /^#/{ next }
                $1==ip{ print $2; exit }
            ' "$_hosts_db" 2>/dev/null)"
            [ -n "$_os" ] || _os="-"
        fi
        printf "  ${_C_GREEN}%-12s${_C_RESET}  %-16s  %-6s  %-10s  %s\n" \
            "$_alias" "$_ip" "$_port" "$_user" "$_os"
    done < "$_devdb"
    printf '\n'
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
    printf "  %-12s  %s\n" "sync"       "nrsync ./dir/ $_ex:~/backup/"
    printf "  %-12s  %s\n" "clipboard"  "nclip $_ex:/remote/file"
    printf "  %-12s  %s\n" "run+copy"   "nclipc $_ex -- <cmd>"
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

        _n=0; _default_alias="d${_n}"
        while awk -F'|' -v a="$_default_alias" '
            /^[[:space:]]*$/{next}/^#/{next}
            $1==a{found=1;exit}END{exit !found}
        ' "$_devdb" 2>/dev/null; do
            _n=$(( _n + 1 )); _default_alias="d${_n}"
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
                $1==a{ printf "%s|%s|%s|%s\n",$1,ni,$3,np; next }{ print }
            ' "$_devdb" > "$_tmp_db"
            mv -f "$_tmp_db" "$_devdb"
            printf '\n'; continue
        fi

        _default_user="u"; _reg_user=""
        while [ -z "$_reg_user" ]; do
            printf "  User [%s]: " "$_default_user"
            read -r _input_user </dev/tty || _input_user=""
            _input_user="$(printf '%s' "$_input_user" | \
                sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
            [ -z "$_input_user" ] && _reg_user="$_default_user" || _reg_user="$_input_user"
        done

        known_hosts_remove_ip "$_ip"
        _tmp_db="$(mktemp "${TMPDIR:-/tmp}/ndevs.XXXXXX")"
        { cat "$_devdb"
          printf '%s|%s|%s|%s\n' "$_alias" "$_ip" "$_reg_user" "${_ssh_port:-22}"
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
