#!/bin/sh
# iface.sh — network interface and subnet detection
#
# Exports:
#   PRIMARY_IFACE  — name of the first usable interface (e.g. eth0, wlan0)
#   MY_IP          — IPv4 address on that interface
#   SUBNET         — CIDR subnet derived from MY_IP + real prefix length
#   GW_IP          — default gateway IP, or .1 of detected subnet as fallback
#
# Strategy:
#   1. Try ip(8) — available on Debian, Arch, modern Termux.
#   2. Fall back to ifconfig — available on older Termux/BSD-style envs.
#   Both paths skip loopback, docker, veth, bridge, tun, wireguard, tailscale.

_IFACE_SKIP_PATTERN="^(lo|docker|veth|br-|dummy|tailscale|tun|wg|virbr|vmnet|ccmni|rmnet|pdp)"

# _iface_via_ifconfig — falls back to ifconfig for older envs.
# Returns "IFACE|IP|" (empty prefix — cannot be reliably extracted).
_iface_via_ifconfig() {
    ifconfig 2>/dev/null \
    | awk '
        /^[a-zA-Z0-9]/ { iface=$1; sub(/:$/,"",iface) }
        /inet / && $2 != "127.0.0.1" {
            ip=""; mask=""
            for(i=1;i<=NF;i++){
                if($i=="inet")  ip=$(i+1)
                if($i=="netmask") mask=$(i+1)
            }
            if(ip=="") next
            pfx=0
            if(mask ~ /^0[xX]/){
                # macOS hex netmask e.g. 0xffffff00 -> count set bits
                h=substr(mask,3); v=0
                for(k=1;k<=length(h);k++){
                    c=tolower(substr(h,k,1))
                    d=index("0123456789abcdef",c)-1
                    v=v*16+d
                }
                while(v>0){pfx+=v%2;v=int(v/2)}
            } else if(mask!=""){
                n=split(mask,o,".")
                for(i=1;i<=n;i++){vv=o[i];while(vv>0){pfx+=vv%2;vv=int(vv/2)}}
            }
            print iface "|" ip "|" pfx
        }
    ' \
    | grep -Ev "$_IFACE_SKIP_PATTERN" \
    | head -1
}

# _iface_from_default_route — interface name backing the default route.
# This is the source of truth for "my real network" on multi-homed hosts.
_iface_from_default_route() {
    ip route show default 2>/dev/null \
    | awk '/^default/ { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
    | head -1
}

# _iface_addr_prefix IFACE — prints "IFACE|IP|PREFIX" for one interface, or empty.
_iface_addr_prefix() {
    ip -4 addr show dev "$1" 2>/dev/null \
    | awk -v ifc="$1" '/inet / { split($2,b,"/"); print ifc "|" b[1] "|" b[2]; exit }'
}

# _list_iface_candidates — every usable iface as "IFACE|IP|PREFIX", skip-filtered.
_list_iface_candidates() {
    ip -4 addr show 2>/dev/null \
    | awk '
        /^[0-9]+: / { split($2,a,"@"); iface=a[1]; sub(/:$/,"",iface) }
        /inet / && iface != "" { split($2,b,"/"); print iface "|" b[1] "|" b[2] }
    ' \
    | grep -Ev "$_IFACE_SKIP_PATTERN"
}

# _iface_from_default_route — interface name backing the default route.
# This is the source of truth for "my real network" on multi-homed hosts.
_iface_from_default_route() {
    ip route show default 2>/dev/null \
    | awk '/^default/ { for (i=1;i<=NF;i++) if ($i=="dev") { print $(i+1); exit } }' \
    | head -1
}

# _iface_addr_prefix IFACE — prints "IFACE|IP|PREFIX" for one interface, or empty.
_iface_addr_prefix() {
    ip -4 addr show dev "$1" 2>/dev/null \
    | awk -v ifc="$1" '/inet / { split($2,b,"/"); print ifc "|" b[1] "|" b[2]; exit }'
}

# _list_iface_candidates — every usable iface as "IFACE|IP|PREFIX", skip-filtered.
_list_iface_candidates() {
    ip -4 addr show 2>/dev/null \
    | awk '
        /^[0-9]+: / { split($2,a,"@"); iface=a[1]; sub(/:$/,"",iface) }
        /inet / && iface != "" { split($2,b,"/"); print iface "|" b[1] "|" b[2] }
    ' \
    | grep -Ev "$_IFACE_SKIP_PATTERN"
}

# _network_addr ip prefix — computes the network address.
# Uses awk integer arithmetic to avoid signed 32-bit overflow in dash/busybox.
_network_addr() {
    printf '%s %s\n' "$1" "$2" | awk '{
        split($1, o, ".")
        ip = (o[1]*16777216) + (o[2]*65536) + (o[3]*256) + o[4]
        pfx = $2
        shift = 32 - pfx
        net = int(ip) - (int(ip) % (shift >= 32 ? 1 : 2^shift))
        printf "%d.%d.%d.%d\n",
            int(net/16777216)%256,
            int(net/65536)%256,
            int(net/256)%256,
            net%256
    }'
}

# detect_iface — sets PRIMARY_IFACE, MY_IP and _DETECTED_PREFIX.
# Exits with error if no usable interface is found.
detect_iface() {
    _result=""

    if [ -n "${NOEMAP_IFACE:-}" ]; then
        _result="$(_iface_addr_prefix "$NOEMAP_IFACE")"
        [ -n "$_result" ] || { log ERROR "interface not usable: $NOEMAP_IFACE"; exit 1; }
    fi

    if [ -z "$_result" ] && has_cmd ip; then
        _dev="$(_iface_from_default_route)" || _dev=""
        [ -n "$_dev" ] && _result="$(_iface_addr_prefix "$_dev")"
    fi

    if [ -z "$_result" ]; then
        _cands="$(_list_iface_candidates)" || _cands=""
        _n="$(printf '%s\n' "$_cands" | grep -c .)" || _n=0
        if [ "$_n" -gt 1 ]; then
            printf '  [?] multiple interfaces:\n' >&2
            printf '%s\n' "$_cands" | nl -w2 -s') ' >&2
            printf '  select: ' >&2
            read -r _sel </dev/tty
            _result="$(printf '%s\n' "$_cands" | sed -n "${_sel}p")"
        else
            _result="$_cands"
        fi
    fi

    if [ -z "$_result" ] && has_cmd ifconfig; then
        _result="$(_iface_via_ifconfig)"
    fi

    if [ -z "$_result" ]; then
        log ERROR "no usable network interface found (tried ip and ifconfig)"
        exit 1
    fi

    PRIMARY_IFACE="${_result%%|*}"
    _rest="${_result#*|}"
    MY_IP="${_rest%%|*}"
    _prefix="${_rest##*|}"

    case "$MY_IP" in
        *.*.*.*)  ;;
        *)
            log ERROR "unexpected IP format from interface detection: '$MY_IP'"
            exit 1
            ;;
    esac

    _DETECTED_PREFIX="$_prefix"
    log INFO "interface: $PRIMARY_IFACE  ip: $MY_IP  prefix: ${_prefix:-unknown}"
}

# detect_network — sets SUBNET and GW_IP.
# Requires MY_IP and _DETECTED_PREFIX (call detect_iface first).
detect_network() {
    _pfx="${_DETECTED_PREFIX:-}"

    case "$_pfx" in
        [89]|[12][0-9]|30) ;;
        *)
            if [ -n "$_pfx" ]; then
                log WARN "unusual prefix length /$_pfx — verify your network topology"
            else
                log WARN "could not determine prefix length — assuming /24"
            fi
            _pfx=24
            ;;
    esac

    if [ "$_pfx" -ne 24 ]; then
        log WARN "detected /$_pfx network (not /24) — nmap will scan correct range; nc fallback still uses /24"
    fi

    _net_addr="$(_network_addr "$MY_IP" "$_pfx")"
    SUBNET="${_net_addr}/${_pfx}"

    GW_IP=""
    if has_cmd ip; then
        GW_IP="$(ip route 2>/dev/null | awk -v ifc="$PRIMARY_IFACE" '/^default/ { for(i=1;i<=NF;i++) if($i=="dev" && $(i+1)==ifc) { for(j=1;j<=NF;j++) if($j=="via") print $(j+1) } }' | head -1)"
    fi

    if [ -z "$GW_IP" ] && has_cmd route; then
        GW_IP="$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/ {print $2; exit}')"
    fi

    if [ -z "$GW_IP" ]; then
        if [ -n "${PREFIX:-}" ]; then
            GW_IP="$MY_IP"
            log WARN "could not detect gateway (Android/no-root) — using self IP: $GW_IP"
        else
            _prefix3="$(printf '%s\n' "$MY_IP" | cut -d. -f1-3)"
            GW_IP="${_prefix3}.1"
            log WARN "could not detect gateway, assuming $GW_IP"
        fi
    fi

    log INFO "subnet: $SUBNET  gateway: $GW_IP"
}
