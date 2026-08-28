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
# Master registry ($HOME/.noemap-registry/registry.db) maps
# node-id -> canonical alias:
#   NODE_ID|ALIAS|USER|PORT
# It is the source of truth for "who is this device", independent of IP.
# The registry lives in its own git-backed repo (github.com:catwilo/noemap-
# registry, cloned to $HOME/.noemap-registry) so identity survives a node
# reformat/reinstall via git, independent of any single node being reachable
# (miko-task#102 precondition; see noemap#51). REGISTRY_DB can still be
# overridden via env var for tests or alternate setups.

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

# _identity_registry_default -- default path for the git-backed registry repo.
_identity_registry_default() {
    printf '%s\n' "$HOME/.noemap-registry/registry.db"
}

REGISTRY_DB="${REGISTRY_DB:-$(_identity_registry_default)}"
MACHINE_SEED="${MACHINE_SEED:-$(_identity_statedir)/machine-seed}"

# NODE_CONFIG -- local per-node cache (offline-first). Not git-backed: this
# is the node's own copy of its alias/user/port, so a node with no network
# access to the master registry (or a fresh clone not yet pulled) still
# knows who it is. Master registry (REGISTRY_DB) remains source of truth
# whenever reachable; this file is the fallback, and is kept in sync with
# it on every successful node_alias_set() (miko-task noemap#295).
NODE_CONFIG="${NODE_CONFIG:-$(_identity_statedir)/node-config}"

# _node_config_load -- prints "ALIAS|USER|PORT" from the local cache file,
# or nothing if absent/empty.
_node_config_load() {
    [ -s "$NODE_CONFIG" ] || return 0
    head -n1 "$NODE_CONFIG" 2>/dev/null
}

# _node_config_save ALIAS USER PORT -- writes the local cache file via
# mkit's atomic flow. Best-effort: a failure here does not block the
# master-registry write, only the local offline fallback.
_node_config_save() {
    _ncs_alias="$1"; _ncs_user="$2"; _ncs_port="$3"
    [ -n "$_ncs_alias" ] && [ -n "$_ncs_user" ] && [ -n "$_ncs_port" ] || {
        printf '[ERROR] _node_config_save: alias, user and port are required\n' >&2
        return 1
    }
    _ncs_dir="$(dirname "$NODE_CONFIG")"
    mkdir -p "$_ncs_dir" 2>/dev/null || true
    _ncs_tmp="$(mktemp "${TMPDIR:-/tmp}/node-config.XXXXXX")"
    printf '%s|%s|%s\n' "$_ncs_alias" "$_ncs_user" "$_ncs_port" > "$_ncs_tmp"
    mkit write "$NODE_CONFIG" "$_ncs_tmp" || {
        rm -f "$_ncs_tmp"
        printf '[ERROR] _node_config_save: mkit write failed\n' >&2
        return 1
    }
}

# _identity_registry_warn_once -- if REGISTRY_DB points at the default
# git-backed path but that repo is not cloned on this node, warn once to
# stderr (not on every node_alias()/node_registry_row() call, which happens
# frequently and would be noisy). Silent no-op once the repo exists, or when
# REGISTRY_DB was overridden away from the default (caller's responsibility).
_IDENTITY_REGISTRY_WARNED="${_IDENTITY_REGISTRY_WARNED:-0}"
_identity_registry_warn_once() {
    [ "$_IDENTITY_REGISTRY_WARNED" = "1" ] && return 0
    [ "$REGISTRY_DB" = "$(_identity_registry_default)" ] || return 0
    [ -d "$HOME/.noemap-registry/.git" ] && return 0
    printf '[WARN] registry repo not found at %s -- clone it: git clone git@github.com:catwilo/noemap-registry.git %s\n' \
        "$HOME/.noemap-registry" "$HOME/.noemap-registry" >&2
    _IDENTITY_REGISTRY_WARNED=1
}

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
    _identity_registry_warn_once
    _nid="$(node_id)"
    [ -f "$REGISTRY_DB" ] || return 0
    awk -F'|' -v id="$_nid" '
        /^[[:space:]]*$/{next}/^#/{next}
        $1==id { print $2; exit }
    ' "$REGISTRY_DB" 2>/dev/null
}

# node_registry_row -- full registry row for this node, or empty.
node_registry_row() {
    _identity_registry_warn_once
    _nid="$(node_id)"
    [ -f "$REGISTRY_DB" ] || return 0
    awk -F'|' -v id="$_nid" '
        /^[[:space:]]*$/{next}/^#/{next}
        $1==id { print; exit }
    ' "$REGISTRY_DB" 2>/dev/null
}

# node_alias_set ALIAS USER PORT -- create or update this node's registry row.
# Fails (return 1, writes nothing) if ALIAS is already taken by a DIFFERENT
# node_id. If this node_id already has a row, that row is updated in place.
# On success: writes REGISTRY_DB via mkit's atomic flow, then commits and
# pushes the registry repo so the change survives a reformat of this node.
node_alias_set() {
    _nas_alias="$1"
    _nas_user="$2"
    _nas_port="$3"
    if [ -z "$_nas_alias" ] || [ -z "$_nas_user" ] || [ -z "$_nas_port" ]; then
        printf '[ERROR] node_alias_set: alias, user and port are required\n' >&2
        return 1
    fi
    _identity_registry_warn_once
    _nas_nid="$(node_id)"
    _nas_dir="$(dirname "$REGISTRY_DB")"
    mkdir -p "$_nas_dir" 2>/dev/null || true
    [ -f "$REGISTRY_DB" ] || : > "$REGISTRY_DB"

    _nas_owner="$(awk -F'|' -v a="$_nas_alias" '
        /^[[:space:]]*$/{next}/^#/{next}
        $2==a { print $1; exit }
    ' "$REGISTRY_DB" 2>/dev/null)"
    if [ -n "$_nas_owner" ] && [ "$_nas_owner" != "$_nas_nid" ]; then
        printf '[ERROR] node_alias_set: alias "%s" already registered to node %s\n' \
            "$_nas_alias" "$_nas_owner" >&2
        return 1
    fi

    _nas_current="$(node_registry_row)"
    _nas_target="${_nas_nid}|${_nas_alias}|${_nas_user}|${_nas_port}"
    [ "$_nas_current" = "$_nas_target" ] && return 0

    _nas_new="$(mktemp "${TMPDIR:-/tmp}/registry.db.XXXXXX")"
    awk -F'|' -v id="$_nas_nid" '
        $1==id { next }
        { print }
    ' "$REGISTRY_DB" > "$_nas_new" 2>/dev/null
    printf '%s|%s|%s|%s\n' "$_nas_nid" "$_nas_alias" "$_nas_user" "$_nas_port" >> "$_nas_new"

    mkit write "$REGISTRY_DB" "$_nas_new" || {
        rm -f "$_nas_new"
        printf '[ERROR] node_alias_set: mkit write failed\n' >&2
        return 1
    }

    _nas_branch="chore/registry-${_nas_nid}"
    ( cd "$_nas_dir" && \
      git checkout main 2>/dev/null && \
      git pull --rebase origin main && \
      git checkout -B "$_nas_branch" && \
      git add registry.db && \
      git commit -m "chore(registry): set alias ${_nas_alias} for node ${_nas_nid}" && \
      git push -u origin "$_nas_branch" --force-with-lease && \
      git checkout main && \
      git merge --ff-only "$_nas_branch" && \
      git push origin main && \
      git branch -d "$_nas_branch" && \
      git push origin --delete "$_nas_branch" ) || {
        printf '[ERROR] node_alias_set: registry.db written locally but branch/commit/push/merge failed -- resolve manually in %s (branch: %s)\n' \
            "$_nas_dir" "$_nas_branch" >&2
        return 1
    }
}

