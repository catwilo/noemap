#!/bin/sh
# devices.sh — device database lookup helpers
#
# Shared by nssh, nscp and any tool that resolves an alias
# to connection details.
#
# Database format: blockdb (lib/blockdb.sh), one block per device:
#   alias: <alias>
#   ip: <ip>
#   user: <user>
#   port: <port>
#   hostkey: <fingerprint or empty>
#
# devices.db is local-only (IP is dynamic, never lives in the cloud
# registry). If port or user is missing locally, this module falls back
# to registry.db (the cloud source of truth, via registry_row_by_alias()
# in identity.sh) before defaulting/prompting. IP has no cloud fallback --
# it only ever comes from local devices.db.

# resolve_device alias db_path — prints "IP|USER|PORT" or exits on error.
resolve_device() {
    _alias="$1"
    _db="$2"

    [ -f "$_db" ] || {
        log ERROR "devices database missing: $_db"
        exit 1
    }

    _blk="$(blockdb_get "$_db" alias "$_alias")"

    [ -n "$_blk" ] || {
        log ERROR "unknown device alias: '$_alias'"
        exit 1
    }

    _ip="$(blockdb_field "$_blk" ip)"
    _user="$(blockdb_field "$_blk" user)"
    _port="$(blockdb_field "$_blk" port)"

    [ -n "$_ip" ] || { log ERROR "devices.db: empty IP for '$_alias'"; exit 1; }

    if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_ip"; then
        log ERROR "refusing self-targeted handshake: '$_alias' resolves to this node's own IP ($_ip)"
        exit 1
    fi

    if command -v registry_row_by_alias >/dev/null 2>&1; then
        _cloud_blk="$(registry_row_by_alias "$_alias")"
        if [ -n "$_cloud_blk" ]; then
            _cloud_port="$(blockdb_field "$_cloud_blk" port)"
            [ -n "$_cloud_port" ] && _port="$_cloud_port"
        fi
    fi
    [ -n "$_port" ] || _port=22

    printf '%s|%s|%s\n' "$_ip" "${_user:-}" "$_port"
}

# ---------------------------------------------------------------------------
# _ensure_user alias db_path current_user
#
# If user is empty or the placeholder "user": try the cloud registry first
# (registry_row_by_alias); if still empty, prompt interactively and persist
# the answer to devices.db. Loops until a non-empty value is given.
# In non-interactive mode with no cloud value, keeps the current value.
# Prints the resolved username to stdout.
# ---------------------------------------------------------------------------
_ensure_user() {
    _eu_alias="$1"
    _eu_db="$2"
    _eu_user="$3"

    case "$_eu_user" in
        ''|user) ;;
        *) printf '%s\n' "$_eu_user"; return 0 ;;
    esac

    if command -v registry_row_by_alias >/dev/null 2>&1; then
        _eu_cloud_blk="$(registry_row_by_alias "$_eu_alias")"
        if [ -n "$_eu_cloud_blk" ]; then
            _eu_cloud_user="$(blockdb_field "$_eu_cloud_blk" user)"
            if [ -n "$_eu_cloud_user" ]; then
                blockdb_upsert "$_eu_db" alias "$_eu_alias" "$(blockdb_get "$_eu_db" alias "$_eu_alias" | sed "s/^user:.*/user: $_eu_cloud_user/")"
                printf '  [i] user "%s" resolved from cloud registry for "%s"\n' "$_eu_cloud_user" "$_eu_alias" >&2
                printf '%s\n' "$_eu_cloud_user"
                return 0
            fi
        fi
    fi

    [ -t 0 ] || { printf '%s\n' "${_eu_user:-}"; return 0; }

    printf '\n  [?] No user set for "%s". Enter SSH username: ' "$_eu_alias" >&2

    while true; do
        read -r _eu_input </dev/tty || _eu_input=""
        _eu_input="$(printf '%s' "$_eu_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [ -z "$_eu_input" ]; then
            printf '  [!] username cannot be empty: ' >&2
            continue
        fi

        _eu_blk="$(blockdb_get "$_eu_db" alias "$_eu_alias")"
        if [ -n "$_eu_blk" ]; then
            _eu_new_blk="$(printf '%s\n' "$_eu_blk" | awk -v nu="$_eu_input" '
                /^user:/ { print "user: " nu; next }
                { print }
            ')"
            blockdb_upsert "$_eu_db" alias "$_eu_alias" "$_eu_new_blk"
        fi

        printf '  [i] user "%s" saved for "%s"\n' "$_eu_input" "$_eu_alias" >&2
        printf '%s\n' "$_eu_input"
        return 0
    done
}

# ---------------------------------------------------------------------------
# resolve_scp_target value db_path
#
# Translates "alias:/path" into "user@ip:/path" using devices.db.
# Plain paths (no colon) are returned unchanged.
# ---------------------------------------------------------------------------
resolve_scp_target() {
    _val="$1"
    _db="$2"

    case "$_val" in
        *:*)
            _alias="${_val%%:*}"
            _path="${_val#*:}"

            _blk="$(blockdb_get "$_db" alias "$_alias")"

            if [ -z "$_blk" ]; then
                printf '%s\n' "$_val"
                return 0
            fi

            _ip="$(blockdb_field "$_blk" ip)"
            _user="$(blockdb_field "$_blk" user)"

            if command -v is_local_ip >/dev/null 2>&1 && [ -n "$_ip" ] && is_local_ip "$_ip"; then
                log ERROR "refusing self-targeted transfer: '$_alias' resolves to this node's own IP ($_ip)"
                exit 1
            fi

            [ -n "$_ip" ] || {
                log ERROR "devices.db: missing IP for alias '$_alias'"
                exit 1
            }

            _user="$(_ensure_user "$_alias" "$_db" "$_user")"

            [ -n "$_user" ] || {
                log ERROR "no user for '$_alias' — aborting transfer"
                exit 1
            }

            printf '%s@%s:%s\n' "$_user" "$_ip" "$_path"
            ;;
        *)
            printf '%s\n' "$_val"
            ;;
    esac
}
