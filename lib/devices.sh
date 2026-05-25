#!/bin/sh
# devices.sh — device database lookup helpers
#
# Shared by nssh, nscp, nrsync and any tool that resolves an alias
# to connection details.
#
# Database format (pipe-delimited, one device per line):
#   ALIAS|IP|USER|PORT
#
# Lines beginning with '#' or blank are ignored.

# resolve_device alias db_path — prints "IP|USER|PORT" or exits on error.
# Uses awk for exact first-field match (immune to regex metacharacters).
resolve_device() {
    _alias="$1"
    _db="$2"

    [ -f "$_db" ] || {
        log ERROR "devices database missing: $_db"
        exit 1
    }

    _line="$(awk -F'|' -v a="$_alias" '$1 == a { print; exit }' "$_db" 2>/dev/null || true)"

    [ -n "$_line" ] || {
        log ERROR "unknown device alias: '$_alias'"
        exit 1
    }

    _ip="$(printf '%s\n'   "$_line" | cut -d'|' -f2)"
    _user="$(printf '%s\n' "$_line" | cut -d'|' -f3)"
    _port="$(printf '%s\n' "$_line" | cut -d'|' -f4)"

    [ -n "$_ip" ]   || { log ERROR "devices.db: empty IP for '$_alias'"; exit 1; }
    [ -n "$_port" ] || _port=22

    printf '%s|%s|%s\n' "$_ip" "${_user:-}" "$_port"
}

# ---------------------------------------------------------------------------
# _ensure_user alias db_path current_user
#
# If user is empty or the placeholder "user", prompts interactively and
# persists the answer to devices.db. Loops until a non-empty value is given.
# In non-interactive mode, keeps the current value.
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

    [ -t 0 ] || { printf '%s\n' "${_eu_user:-}"; return 0; }

    printf '\n  [?] No user set for "%s". Enter SSH username: ' "$_eu_alias" >&2

    while true; do
        read -r _eu_input </dev/tty || _eu_input=""
        _eu_input="$(printf '%s' "$_eu_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [ -z "$_eu_input" ]; then
            printf '  [!] username cannot be empty: ' >&2
            continue
        fi

        _eu_tmp="$(mktemp "${TMPDIR:-/tmp}/ndevs.XXXXXX")"
        awk -F'|' -v a="$_eu_alias" -v nu="$_eu_input" '
            /^[[:space:]]*$/ { print; next }
            /^#/             { print; next }
            $1 == a          { printf "%s|%s|%s|%s\n", $1, $2, nu, $4; next }
            { print }
        ' "$_eu_db" > "$_eu_tmp" && mv -f "$_eu_tmp" "$_eu_db" || rm -f "$_eu_tmp"

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

            _line="$(awk -F'|' -v a="$_alias" '$1 == a { print; exit }' "$_db" 2>/dev/null || true)"

            if [ -z "$_line" ]; then
                printf '%s\n' "$_val"
                return 0
            fi

            _ip="$(printf '%s\n'   "$_line" | cut -d'|' -f2)"
            _user="$(printf '%s\n' "$_line" | cut -d'|' -f3)"

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
