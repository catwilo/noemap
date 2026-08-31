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
    _blk="$(blockdb_get "$_odb" alias "$_oda")"
    [ -n "$_blk" ] || return 0
    blockdb_field "$_blk" ip
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
    _blk="$(blockdb_get "$REGISTRY_DB" node_id "$_nid")"
    [ -n "$_blk" ] || return 0
    blockdb_field "$_blk" alias
}

# node_registry_row -- full registry row for this node, or empty.
node_registry_row() {
    _identity_registry_warn_once
    _nid="$(node_id)"
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" node_id "$_nid"
}

# _registry_write NODE_ID ALIAS USER PORT -- single source of truth for
# writing any row in registry.db: this node's own identity or another
# node's, by explicit node-id. Fails (return 1, writes nothing) if ALIAS
# is already taken by a DIFFERENT node_id. Hostkey resolution: if NODE_ID
# is this machine's own node_id, scans its local sshd (127.0.0.1:PORT,
# no auth); otherwise preserves whatever hostkey the row already had
# (never guessable for a remote node without SSH auth to it).
# On success: writes REGISTRY_DB via mkit's atomic flow, then commits and
# pushes the registry repo (fixed branch chore/registry-<node-id>,
# ff-only merge -- fails loud instead of a silent merge commit on
# divergence), then distributes to every reachable node.
# Fix noemap#407: the working-tree branch is created and rebased onto
# origin/main FIRST, before mkit write ever touches registry.db, so the
# later 'git pull --rebase' never runs against a dirty tree.
_registry_write() {
    _rw_nid="$1"
    _rw_alias="$2"
    _rw_user="$3"
    _rw_port="$4"
    if [ -z "$_rw_nid" ] || [ -z "$_rw_alias" ] || [ -z "$_rw_user" ] || [ -z "$_rw_port" ]; then
        printf '[ERROR] _registry_write: node-id, alias, user and port are required\n' >&2
        return 1
    fi
    _identity_registry_warn_once
    _rw_dir="$(dirname "$REGISTRY_DB")"
    mkdir -p "$_rw_dir" 2>/dev/null || true
    [ -f "$REGISTRY_DB" ] || : > "$REGISTRY_DB"

    _rw_branch="chore/registry-${_rw_nid}"
    ( cd "$_rw_dir" && \
      git checkout main 2>/dev/null && \
      git pull --rebase origin main && \
      git checkout -B "$_rw_branch" ) || {
        printf '[ERROR] _registry_write: could not prepare branch %s in %s -- aborting before any write\n' \
            "$_rw_branch" "$_rw_dir" >&2
        return 1
    }

    _rw_owner_blk="$(blockdb_get "$REGISTRY_DB" alias "$_rw_alias")"
    _rw_owner="$([ -n "$_rw_owner_blk" ] && blockdb_field "$_rw_owner_blk" node_id || printf '')"
    if [ -n "$_rw_owner" ] && [ "$_rw_owner" != "$_rw_nid" ]; then
        printf '[ERROR] _registry_write: alias "%s" already registered to node %s\n' \
            "$_rw_alias" "$_rw_owner" >&2
        return 1
    fi

    _rw_prev_hk=""
    _rw_prev_row="$(blockdb_get "$REGISTRY_DB" node_id "$_rw_nid")"
    [ -n "$_rw_prev_row" ] && _rw_prev_hk="$(blockdb_field "$_rw_prev_row" hostkey)"

    _rw_hk="$_rw_prev_hk"
    if [ "$_rw_nid" = "$(node_id)" ] && command -v _get_host_key_fingerprint >/dev/null 2>&1; then
        _rw_scanned_hk="$(_get_host_key_fingerprint 127.0.0.1 "$_rw_port" 2>/dev/null)"
        # keep previous value if this run's scan produced nothing (best-effort)
        _rw_hk="${_rw_scanned_hk:-$_rw_prev_hk}"
    fi

    _rw_current="$_rw_prev_row"
    _rw_target="$(printf 'node_id: %s\nalias: %s\nuser: %s\nport: %s\nhostkey: %s\n' \
        "$_rw_nid" "$_rw_alias" "$_rw_user" "$_rw_port" "${_rw_hk:-}")"
    [ "$_rw_current" = "$_rw_target" ] && return 0

    blockdb_upsert "$REGISTRY_DB" node_id "$_rw_nid" "$_rw_target"

    ( cd "$_rw_dir" && \
      git add registry.db && \
      git commit -m "chore(registry): set alias ${_rw_alias} for node ${_rw_nid}" && \
      git push -u origin "$_rw_branch" --force-with-lease && \
      git checkout main && \
      git merge --ff-only "$_rw_branch" && \
      git push origin main && \
      git branch -d "$_rw_branch" && \
      git push origin --delete "$_rw_branch" ) || {
        printf '[ERROR] _registry_write: registry.db written locally but commit/push/merge failed -- resolve manually in %s (branch: %s)\n' \
            "$_rw_dir" "$_rw_branch" >&2
        return 1
    }

    _distribute_registry
}

# node_alias_set ALIAS USER PORT -- create or update THIS node's registry
# row. Thin wrapper over _registry_write using this machine's own node_id
# (guarantees local hostkey scanning applies). See _registry_write for
# the full contract.
node_alias_set() {
    _nas_alias="$1"
    _nas_user="$2"
    _nas_port="$3"
    if [ -z "$_nas_alias" ] || [ -z "$_nas_user" ] || [ -z "$_nas_port" ]; then
        printf '[ERROR] node_alias_set: alias, user and port are required\n' >&2
        return 1
    fi
    _registry_write "$(node_id)" "$_nas_alias" "$_nas_user" "$_nas_port"
}


# registry_row_by_alias ALIAS -- full registry.db block for the given alias
# (cloud source of truth), or empty if REGISTRY_DB missing or alias unknown.
# Complements node_registry_row(), which looks up by node_id (this node's
# own identity); this looks up any OTHER node by its alias.
registry_row_by_alias() {
    _rrba_alias="$1"
    [ -n "$_rrba_alias" ] || return 0
    _identity_registry_warn_once
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" alias "$_rrba_alias"
}

# registry_row_by_hostkey HOSTKEY -- full registry.db block for the given
# SSH host key fingerprint (cloud source of truth), or empty if REGISTRY_DB
# missing or no node has that hostkey recorded. Twin of registry_row_by_alias,
# used to resolve a genuinely-new-to-this-node host that already has a row
# in the cloud registry under a different node, without SSH auth.
registry_row_by_hostkey() {
    _rrbh_hk="$1"
    [ -n "$_rrbh_hk" ] || return 0
    _identity_registry_warn_once
    [ -f "$REGISTRY_DB" ] || return 0
    blockdb_get "$REGISTRY_DB" hostkey "$_rrbh_hk"
}

# _distribute_registry -- ensure every known node's ~/.noemap-registry clone
# is up to date via nssh + git pull, skipping self. Called after every
# registry change so identity is never stale. Shared by node_alias_set()
# here and ndevs --node-add/--registry-set (bin/ndevs) -- single source of
# truth, moved here from bin/ndevs (ut#443 follow-up, noemap#448).
# REDESIGN (noemap#447/#448 investigation): the previous implementation
# nssh-copied a raw file to ~/.local/share/noemap/state/registry.db, which
# is NOT the path ndevs/identity.sh actually read (REGISTRY_DB default is
# ~/.noemap-registry/registry.db, the git-backed repo). That left remote
# nodes' real registry stuck on old commits (old pipe format, stale
# aliases), even though the copied file looked fine. Correct mechanism:
# have each remote node pull its own git clone, then verify convergence by
# comparing HEAD commit hashes -- printing an explicit MATCH/DIFF per node
# instead of a bare OK that hides a stale clone.
_distribute_registry() {
    _dr_devdb="$(_identity_statedir)/devices.db"
    [ -f "$REGISTRY_DB" ] || return 0
    has_cmd nssh || { log WARN "nssh not found -- registry not distributed"; return 0; }
    [ -f "$_dr_devdb" ] || return 0
    _dr_local_head="$(cd "$(dirname "$REGISTRY_DB")" 2>/dev/null && git rev-parse HEAD 2>/dev/null)"
    _my_alias="$(node_alias 2>/dev/null || printf '')"
    _dr_fail_count="$(mktemp "${TMPDIR:-/tmp}/distribute-registry-fails.XXXXXX")"
    _dr_aliases="$(awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ' "$_dr_devdb" 2>/dev/null)"
    printf '%s\n' "$_dr_aliases" | while IFS= read -r _na; do
        [ -n "$_na" ] || continue
        [ "$_na" = "$_my_alias" ] && continue
        _nblk="$(blockdb_get "$_dr_devdb" alias "$_na")"
        [ -n "$_nblk" ] || continue
        _nip="$(blockdb_field "$_nblk" ip)"
        _nport="$(blockdb_field "$_nblk" port)"
        [ -n "$_nport" ] || _nport=22
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_nip"; then continue; fi
        case "$_nip" in 127.*|localhost) continue ;; esac
        if ! reachable_ssh "$_nip" "$_nport"; then
            log WARN "registry -> $_na skipped (unreachable: $_nip:$_nport)"
            continue
        fi
        _dr_remote_head="$(nssh "$_na" "cd ~/.noemap-registry 2>/dev/null && git pull --rebase origin main >/dev/null 2>&1 && git rev-parse HEAD 2>/dev/null" 2>/dev/null)"
        if [ -z "$_dr_remote_head" ]; then
            log WARN "registry pull on $_na failed or repo not cloned -- skipped"
            printf 'x' >> "$_dr_fail_count"
            continue
        fi
        if [ -n "$_dr_local_head" ] && [ "$_dr_remote_head" = "$_dr_local_head" ]; then
            log OK "registry synced -> $_na (MATCH $_dr_remote_head)"
            # Point (5): bidirectional handshake in one run -- if the remote
            # node's own row in this (now-confirmed-current) REGISTRY_DB has
            # no hostkey yet, trigger its own node-set remotely via nssh so
            # it self-registers without a manual step on that machine. Uses
            # user/port already known locally in devices.db for that alias
            # (the credentials this node uses to reach it); node_alias_set
            # on the remote side is idempotent (no-op if already current).
            _dr_remote_hk_blk="$(blockdb_get "$REGISTRY_DB" alias "$_na")"
            _dr_remote_hk="$([ -n "$_dr_remote_hk_blk" ] && blockdb_field "$_dr_remote_hk_blk" hostkey || printf '')"
            if [ -z "$_dr_remote_hk" ]; then
                _dr_nuser="$(blockdb_field "$_nblk" user)"; _dr_nuser="${_dr_nuser:-u}"
                if nssh "$_na" "command -v ndevs >/dev/null 2>&1 && ndevs --node-set '$_na' '$_dr_nuser' '$_nport'" >/dev/null 2>&1; then
                    log OK "triggered remote hostkey registration on $_na"
                else
                    log WARN "could not trigger remote hostkey registration on $_na -- run 'ndevs --node-set $_na' there manually"
                fi
            fi
        else
            log WARN "registry synced -> $_na (DIFF: local=${_dr_local_head:-?} remote=$_dr_remote_head)"
            printf 'x' >> "$_dr_fail_count"
        fi
    done
    _dr_fails="$(wc -c < "$_dr_fail_count" 2>/dev/null || printf 0)"
    rm -f "$_dr_fail_count"
    [ "${_dr_fails:-0}" -eq 0 ]
}
