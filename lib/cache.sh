#!/bin/sh
# cache.sh — persistent state cache for noemap
#
# Format: simple KEY=VALUE shell snippet. Values are validated before
# assignment to prevent injection (no eval of untrusted data).
#
# Lifecycle:
#   load_cache  — called before detection; populates vars if cache is fresh
#   save_cache  — called after successful detection; persists current state

CACHE="$BASE/state/cache.env"

# Maximum cache age in seconds before treated as stale (6 hours)
_CACHE_MAX_AGE=21600

# _cache_set key value — assigns a validated cache variable by name.
# Replaces eval; handles only the known safe set of keys.
_cache_set() {
    _ck="$1"
    _cv="$2"
    case "$_ck" in
        MY_IP)          MY_IP="$_cv"          ;;
        GW_IP)          GW_IP="$_cv"          ;;
        SUBNET)         SUBNET="$_cv"         ;;
        PRIMARY_IFACE)  PRIMARY_IFACE="$_cv"  ;;
        DEB_IP)         DEB_IP="$_cv"         ;;
        LAST_SCAN)      LAST_SCAN="$_cv"      ;;
    esac
}

# load_cache — sources the cache file if it exists and is recent enough.
# Uses LAST_SCAN stored in the cache itself (POSIX-portable, no stat -c).
load_cache() {
    [ -f "$CACHE" ] || return 0

    # Read LAST_SCAN first for staleness check
    _last_scan=0
    while IFS= read -r _line; do
        case "$_line" in
            LAST_SCAN=*) _last_scan="${_line#LAST_SCAN=}" ;;
        esac
    done < "$CACHE"

    _now="$(date +%s 2>/dev/null || printf '0')"
    _age=$(( _now - _last_scan ))

    if [ "$_last_scan" -eq 0 ] || [ "$_age" -gt "$_CACHE_MAX_AGE" ]; then
        log INFO "cache stale (${_age}s old), skipping"
        return 0
    fi

    # Validate and assign only safe KEY=VALUE lines (no eval)
    while IFS= read -r _line; do
        case "$_line" in
            ''|'#'*) continue ;;
        esac

        _key="${_line%%=*}"
        _val="${_line#*=}"

        # Only known keys are accepted
        case "$_key" in
            MY_IP|GW_IP|SUBNET|PRIMARY_IFACE|DEB_IP|LAST_SCAN) ;;
            *) log WARN "cache: unknown key '$_key', skipping"; continue ;;
        esac

        # Reject values containing shell metacharacters
        case "$_val" in
            *[\;\`\$\(\)\{\}\|\&\<\>\\\"\'!]*)
                log WARN "cache: unsafe value for '$_key', skipping"
                continue
                ;;
        esac

        _cache_set "$_key" "$_val"

    done < "$CACHE"

    log INFO "cache loaded (age: ${_age}s)"
}

# save_cache — atomically writes current state to the cache file.
# Refuses to write if critical variables are empty.
save_cache() {
    if [ -z "${MY_IP:-}" ] || [ -z "${SUBNET:-}" ]; then
        log WARN "save_cache: MY_IP or SUBNET is empty — cache not updated"
        return 0
    fi

    _ts="$(date +%s 2>/dev/null || printf '0')"

    atomic_write "$CACHE" <<EOF
MY_IP=${MY_IP}
GW_IP=${GW_IP:-}
SUBNET=${SUBNET}
PRIMARY_IFACE=${PRIMARY_IFACE:-}
DEB_IP=${DEB_IP:-}
LAST_SCAN=${_ts}
EOF

    log INFO "cache saved"
}
