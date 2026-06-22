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
