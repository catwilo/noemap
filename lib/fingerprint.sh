#!/bin/sh
# fingerprint.sh — SSH port detection and device database management
#
# Reads HOST_LIST (SSH-filtered by scan.sh).
# Probes open SSH ports per host, classifies type, stores to hosts.db.
# New host registration happens post-display in output.sh → prompt_new_hosts.
#
# Design:
#   • Fast mode (default): type classification via port heuristic only.
#     No banner grabs, no nmap -sV — safe and fast in Termux/no-root.
#   • Deep mode (--deep): adds SSH banner via nmap -sV to distinguish
#     Termux/Android from Debian/Ubuntu on port 22.
#   • Self-IP is excluded (scan.sh filters it, double-checked here).
#   • IP changes are handled automatically (known_hosts cleaned).

HOSTS_DB="$BASE/state/hosts.db"
DEVICES_DB="$BASE/state/devices.db"

_FP_SSH_PORTS="22,8022,2222"

# ---------------------------------------------------------------------------
# DB structural validation
# ---------------------------------------------------------------------------
_validate_db() {
    _db="$1"
    [ -f "$_db" ] || return 0
    awk -F'|' '
        /^[[:space:]]*$/ { next }
        /^#/             { next }
        NF < 2           { exit 1 }
    ' "$_db"
}

# ---------------------------------------------------------------------------
# SSH port detection per host
# ---------------------------------------------------------------------------
_detect_ssh_port() {
    _ip="$1"
    _fp_nmap_out="$2"

    if [ -s "$_fp_nmap_out" ]; then
        _p="$(awk -v host="$_ip" '
            /Nmap scan report for / { in_host = ($NF == host) }
            in_host && /\/tcp.*open/ {
                split($1, a, "/")
                print a[1]; exit
            }
        ' "$_fp_nmap_out")"
        [ -n "$_p" ] && { printf '%s\n' "$_p"; return 0; }
    fi

    for _p in 22 8022 2222; do
        nc -z -w 2 "$_ip" "$_p" >/dev/null 2>&1 && { printf '%s\n' "$_p"; return 0; }
    done
    printf '22\n'
}

# ---------------------------------------------------------------------------
# SSH banner grab (deep mode only)
# ---------------------------------------------------------------------------
_get_ssh_banner() {
    _bip="$1"; _bport="$2"
    # Fiable y nativo: leer la cadena de identificacion del protocolo SSH
    # directo del socket (bash /dev/tcp). El servidor la envia al conectar.
    # Linux trae sufijo de distro (OpenSSH_x Debian-...); macOS va bare.
    _b="$(timeout 4 bash -c 'exec 3<>/dev/tcp/'"$_bip"'/'"$_bport"' && head -1 <&3' 2>/dev/null)"
    [ -n "$_b" ] && { printf '%s' "$_b"; return 0; }
    # Fallback: nmap si el socket directo fallo
    has_cmd nmap || return 0
    nmap -Pn -n -sV --version-intensity 5 \
        --host-timeout 5s -p "$_bport" "$_bip" 2>/dev/null \
    | awk '/open.*ssh/{ print; exit }'
}

# ---------------------------------------------------------------------------
# Type classification
#
# Fast mode: port heuristic only.
#   8022  → android-ssh  (Termux default port)
#   2222  → linux-ssh    (common non-root Linux sshd)
#   22    → linux-ssh    (generic; use --deep to distinguish Termux)
#
# Deep mode (NOEMAP_DEEP=1): adds SSH banner to distinguish Termux from
#   Debian/Ubuntu on port 22.
# ---------------------------------------------------------------------------
_detect_type() {
    _ttl="$1"; _ssh_port="$2"; _ip="${3:-}"

    case "$_ttl" in
        128|127) printf 'windows'; return ;;
        255)     printf 'router';  return ;;
    esac

    [ -z "$_ssh_port" ] && { printf 'linux'; return; }

    case "$_ssh_port" in
        8022) printf 'android-ssh'; return ;;
        2222) printf 'linux-ssh';   return ;;
    esac

    # Fast passive banner grab (free, no login). Distros self-identify;
    # macOS ships a bare "OpenSSH_x.y" with no platform suffix.
    _banner="$(_get_ssh_banner "$_ip" "$_ssh_port" 2>/dev/null || true)"
    case "$_banner" in
        *[Uu]buntu*|*[Dd]ebian*|*[Aa]lpine*|*[Aa]rch*|*[Ff]edora*|*[Rr]aspbian*|*[Mm]int*|*[Gg]entoo*|*[Ss][Uu][Ss][Ee]*|*armbian*)
            printf 'linux-ssh'; return ;;
    esac

    # Bare OpenSSH + Unix TTL: macOS is the typical LAN match, since Linux
    # almost always carries a distro suffix (caught above).
    case "$_banner" in
        SSH-2.0-OpenSSH_[0-9]*)
            case "$_ttl" in
                64|63) printf 'mac'; return ;;
            esac
            printf 'unix-ssh'; return ;;
    esac

    # Deep mode: confirm any remaining ambiguity with nmap -O if available.
    if [ "${NOEMAP_DEEP:-0}" = "1" ] && [ -n "${_FP_OS_OUT:-}" ] && [ -s "${_FP_OS_OUT:-/nonexistent}" ]; then
        _os_line="$(awk -v host="$_ip" '
            /Nmap scan report for / { found = ($NF == host) }
            found && (/OS details:/ || /Running:/ || /OS guess/) { print; exit }
        ' "$_FP_OS_OUT" 2>/dev/null)"
        case "$_os_line" in
            *[Dd]arwin*|*[Aa]pple*|*macOS*) printf 'mac';      return ;;
            *[Ww]indows*)                   printf 'windows';  return ;;
            *[Ll]inux*)                     printf 'linux-ssh'; return ;;
        esac
    fi

    # Empty/unreadable banner: do NOT assume macOS — could be filtered,
    # refused, or a non-SSH host. Classify as unknown.
    case "$_banner" in
        "") printf 'unknown'; return ;;
    esac
    printf 'linux-ssh'
}

# ---------------------------------------------------------------------------
# fingerprint_hosts — main entry point
# ---------------------------------------------------------------------------
fingerprint_hosts() {
    _host_count=0
    if [ -n "${HOST_LIST:-}" ]; then
        _host_count="$(printf '%s\n' "$HOST_LIST" | wc -l | tr -d ' ')"
    fi
    log INFO "fingerprinting ${_host_count} host(s)"

    _hosts_partial="$(session_tmp hosts_partial)"
    : > "$_hosts_partial"
    DEB_IP=""

    [ -n "${HOST_LIST:-}" ] || {
        log INFO "no hosts to fingerprint"
        return 0
    }

    # Batch SSH port scan across all discovered hosts
    _fp_nmap_out="$(session_tmp fp_nmap_out)"
    if has_cmd nmap; then
        _fp_host_file="$(session_tmp fp_hosts)"
        printf '%s\n' "$HOST_LIST" > "$_fp_host_file"
        nmap -Pn -n --host-timeout 4s -p "$_FP_SSH_PORTS" \
            -iL "$_fp_host_file" 2>/dev/null > "$_fp_nmap_out" || true
    fi

    # Deep OS fingerprint (one batch, root only). Termux/no-sudo skip silently
    # and fall back to passive banner+TTL classification in _detect_type.
    _FP_OS_OUT=""
    if [ "${NOEMAP_DEEP:-0}" = "1" ] && has_cmd nmap; then
        _os_out="$(session_tmp fp_os_out)"
        if [ "$(id -u)" = "0" ]; then
            nmap -Pn -n -O --osscan-guess --host-timeout 20s \
                -iL "$_fp_host_file" 2>/dev/null > "$_os_out" & 
            _spin_wait "$!" "OS fingerprint" || true
            _FP_OS_OUT="$_os_out"
        elif has_cmd sudo && [ -z "${PREFIX:-}" ]; then
            if sudo -v 2>/dev/null; then
                sudo nmap -Pn -n -O --osscan-guess --host-timeout 20s \
                    -iL "$_fp_host_file" 2>/dev/null > "$_os_out" & 
                _spin_wait "$!" "OS fingerprint" || true
                _FP_OS_OUT="$_os_out"
            fi
        fi
    fi

    # Per-host: TTL + SSH port → classify + record
    _deb_marker="$(session_tmp deb_ip)"

    printf '%s\n' "$HOST_LIST" > "$(session_tmp fp_host_list)"
    while IFS= read -r _ip; do
        [ -n "$_ip" ]          || continue
        [ "$_ip" = "$MY_IP" ] && continue   # skip self (double-check)

        # TTL via ping
        _ttl=""
        _ttl_raw="$(ping -c 1 -W 1 "$_ip" 2>/dev/null || true)"
        case "$_ttl_raw" in
            *[Tt][Tt][Ll]=*)
                _ttl="$(printf '%s\n' "$_ttl_raw" \
                    | sed -n 's/.*[Tt][Tt][Ll]=\([0-9]*\).*/\1/p' | head -1)" ;;
        esac

        _ssh_port="$(_detect_ssh_port "$_ip" "$_fp_nmap_out")"

        # All open ports (for display in --ports mode)
        _all_ports=""
        if [ -s "$_fp_nmap_out" ]; then
            _all_ports="$(awk -v host="$_ip" '
                /Nmap scan report for / { in_host = ($NF == host) }
                in_host && /\/tcp.*open/ {
                    split($1, a, "/"); printf "%s,", a[1]
                }
            ' "$_fp_nmap_out" | sed 's/,$//')"
        fi

        _type="$(_detect_type "${_ttl:-}" "$_ssh_port" "$_ip")"

        log INFO "host $_ip  ttl=${_ttl:-?}  ssh=${_ssh_port:-none}  ports=${_all_ports:-none}  type=$_type"

        # Format: IP|TYPE|TTL|SSH_PORT|ALL_PORTS
        printf '%s|%s|%s|%s|%s\n' \
            "$_ip" "$_type" "${_ttl:-0}" "${_ssh_port:-22}" "${_all_ports:-}" \
            >> "$_hosts_partial"

        if [ "$_type" = "linux-ssh" ] && [ ! -f "$_deb_marker" ]; then
            printf '%s\n' "$_ip" > "$_deb_marker"
        fi
    done < "$(session_tmp fp_host_list)"

    # Promote hosts.db atomically
    if [ -s "$_hosts_partial" ]; then
        if _validate_db "$_hosts_partial"; then
            atomic_write "$HOSTS_DB" < "$_hosts_partial"
        else
            log WARN "fingerprint validation failed — hosts.db left intact"
        fi
    fi

    # Recover DEB_IP from marker (subshell barrier)
    [ -f "$_deb_marker" ] && DEB_IP="$(cat "$_deb_marker")"

    [ -f "$DEVICES_DB" ] || touch "$DEVICES_DB"
    [ -s "$_hosts_partial" ] && _update_registered_hosts "$_hosts_partial"

    # Prune stale known_hosts
    known_hosts_prune "$DEVICES_DB"
}

# ---------------------------------------------------------------------------
# _update_registered_hosts — update SSH port for already-registered IPs
# if it changed. New hosts go to prompt_new_hosts in output.sh.
# ---------------------------------------------------------------------------
_update_registered_hosts() {
    _partial="$1"

    while IFS='|' read -r _ip _type _ttl _ssh_port _all_ports; do
        [ -n "$_ip" ] || continue

        _existing="$(awk -F'|' -v ip="$_ip" '
            /^[[:space:]]*$/ { next }
            /^#/             { next }
            $2 == ip         { print $1; exit }
        ' "$DEVICES_DB" 2>/dev/null)"

        [ -n "$_existing" ] || continue   # new host — handled by prompt_new_hosts

        _cur_port="$(awk -F'|' -v ip="$_ip" '
            /^[[:space:]]*$/ { next }
            /^#/             { next }
            $2 == ip         { print $4; exit }
        ' "$DEVICES_DB" 2>/dev/null)"
        _cur_port="${_cur_port:-22}"

        if [ -n "$_ssh_port" ] && [ "$_ssh_port" != "$_cur_port" ]; then
            _tmp_db="$(mktemp "${TMPDIR:-/tmp}/ndevs.XXXXXX")"
            awk -F'|' -v ip="$_ip" -v np="$_ssh_port" '
                /^[[:space:]]*$/ { print; next }
                /^#/             { print; next }
                $2 == ip         { printf "%s|%s|%s|%s\n",$1,$2,$3,np; next }
                { print }
            ' "$DEVICES_DB" > "$_tmp_db"
            mv -f "$_tmp_db" "$DEVICES_DB"
            log INFO "updated SSH port for '$_existing': $_cur_port → $_ssh_port"
        else
            log INFO "host $_ip already registered as '$_existing'"
        fi
    done < "$_partial"
}

# ---------------------------------------------------------------------------
# new_hosts_list — prints IPs from hosts.db not yet in devices.db.
# Used by prompt_new_hosts in output.sh.
# ---------------------------------------------------------------------------
new_hosts_list() {
    _hdb="$HOSTS_DB"
    _ddb="$DEVICES_DB"
    [ -f "$_hdb" ] && [ -s "$_hdb" ] || return 0

    while IFS='|' read -r _ip _type _ttl _ssh_port _all_ports; do
        [ -n "$_ip" ] || continue
        _found="$(awk -F'|' -v ip="$_ip" '
            /^[[:space:]]*$/ { next }
            /^#/             { next }
            $2 == ip         { print 1; exit }
        ' "$_ddb" 2>/dev/null)"
        [ -z "$_found" ] && printf '%s|%s|%s\n' "$_ip" "$_type" "${_ssh_port:-22}"
    done < "$_hdb"
}
