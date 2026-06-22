#!/bin/sh
# identity.sh -- stable per-node identity for noemap.
#
# Provides a single 16-hex node-id per device, uniform across Debian, Termux,
# Arch and Windows. The id derives from a filesystem seed (NOT hardware), so a
# reinstall/format yields a new id by design.
#
# Seed resolution (first hit wins):
#   1. /etc/machine-id           -- systemd/Debian canonical id.
#   2. $STATEDIR/machine-seed    -- portable fallback; a UUID v4 generated once
#                                   and persisted (Termux/Android, Windows, Arch).
#
# The seed is never transmitted raw: node_id() emits SHA-256 truncated to 16
# hex chars (follows systemd guidance against leaking machine-id directly).
#
# Master registry ($STATEDIR/registry.db) maps node-id -> canonical alias:
#   NODE_ID|ALIAS|USER|PORT
# It is the source of truth for "who is this device", independent of IP.

# _identity_statedir -- resolve the state dir consistently with the rest of noemap.
_identity_statedir() {
    if [ -n "${NOEMAP_DATA:-}" ] && [ -d "$NOEMAP_DATA" ]; then
        printf '%s\n' "$NOEMAP_DATA/state"
    elif [ -n "${BASE:-}" ] && [ -d "$BASE/state" ]; then
        printf '%s\n' "$BASE/state"
    else
        printf '%s\n' "$HOME/.local/share/noemap/state"
    fi
}

REGISTRY_DB="${REGISTRY_DB:-$(_identity_statedir)/registry.db}"
MACHINE_SEED="${MACHINE_SEED:-$(_identity_statedir)/machine-seed}"

# _gen_uuid -- emit a fresh UUID v4 from the most portable source available.
_gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        printf '%s-%s-%s\n' "$(date +%s%N 2>/dev/null || date +%s)" "$$" "${RANDOM:-0}${RANDOM:-0}"
    fi
}

# _machine_seed -- return the raw seed string, creating the portable one if needed.
_machine_seed() {
    if [ -r /etc/machine-id ]; then
        cat /etc/machine-id
        return 0
    fi
    if [ ! -s "$MACHINE_SEED" ]; then
        _ms_dir="$(dirname "$MACHINE_SEED")"
        mkdir -p "$_ms_dir" 2>/dev/null || true
        _gen_uuid > "$MACHINE_SEED" 2>/dev/null || true
        chmod 600 "$MACHINE_SEED" 2>/dev/null || true
    fi
    cat "$MACHINE_SEED" 2>/dev/null
}

# _sha256 -- portable sha256, prints only the hex digest.
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 | awk '{print $NF}'
    else
        cksum | awk '{printf "%08x%08x\n",$1,$2}'
    fi
}

# _local_ips -- every IPv4 address bound to this device (one per line).
# Used to guarantee distribution never targets the local machine, regardless
# of whether MY_IP is exported (e.g. when ndevs runs outside a noemap scan).
_local_ips() {
    # ifconfig with NO arguments is the only enumeration that works on Termux/
    # Android without root (ip -4 addr show / /proc/net/dev are permission-denied).
    # IPs are read live every call so a dynamic, router-assigned address is
    # always current -- we never pin an IP.
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet /{for(i=1;i<=NF;i++) if($i=="inet"){v=$(i+1); sub(/^addr:/,"",v); print v}}'
    elif command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1]}'
    fi
    printf '127.0.0.1\n'
}

# is_local_ip IP -- return 0 if IP belongs to this device (or is loopback).
# _own_devices_ip -- the IP bound to THIS node's canonical alias in devices.db.
# This is "me" by definition even if the interface that had it is now down
# (IPs are dynamic/router-assigned), so it complements live ifconfig lookup.
_own_devices_ip() {
    _oda="$(node_alias 2>/dev/null)"
    [ -n "$_oda" ] || return 0
    _odb="$(_identity_statedir)/devices.db"
    [ -f "$_odb" ] || return 0
    awk -F'|' -v a="$_oda" '
        /^[[:space:]]*$/{next}/^#/{next}$1==a{print $2;exit}
    ' "$_odb" 2>/dev/null
}

is_local_ip() {
    _q="$1"
    [ -n "$_q" ] || return 1
    case "$_q" in 127.*|localhost) return 0 ;; esac
    [ -n "${MY_IP:-}" ] && [ "$_q" = "$MY_IP" ] && return 0
    # the IP of our own canonical row is always us (survives interface down)
    [ "$_q" = "$(_own_devices_ip)" ] && return 0
    _local_ips | grep -qxF "$_q"
}

# node_id -- the canonical 16-hex identifier for this device.
node_id() {
    _machine_seed | _sha256 | cut -c1-16
}

# node_alias -- canonical alias for this node from the master registry, or empty.
node_alias() {
    _nid="$(node_id)"
    [ -f "$REGISTRY_DB" ] || return 0
    awk -F'|' -v id="$_nid" '
        /^[[:space:]]*$/{next}/^#/{next}
        $1==id { print $2; exit }
    ' "$REGISTRY_DB" 2>/dev/null
}

# node_registry_row -- full registry row for this node, or empty.
node_registry_row() {
    _nid="$(node_id)"
    [ -f "$REGISTRY_DB" ] || return 0
    awk -F'|' -v id="$_nid" '
        /^[[:space:]]*$/{next}/^#/{next}
        $1==id { print; exit }
    ' "$REGISTRY_DB" 2>/dev/null
}
