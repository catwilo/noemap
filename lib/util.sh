#!/bin/sh
# util.sh — shared helpers for the noemap suite
#
# Sourced by noemap and all bin/* tools. Must work under /bin/sh
# (dash, bash, busybox ash). No global mutable state except
# SESSION_TMP_DIR (set once by init_session).

# ---------------------------------------------------------------------------
# Logging — stderr + append to log file
# ---------------------------------------------------------------------------
# log LEVEL message...
# Writes "[LEVEL] message" to stderr; appends timestamped line to log file.
# Log is rotated at ~200 KB.
log() {
    _lvl="$1"
    shift
    _msg="$*"
    _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')"
    printf '[%s] %s\n' "$_lvl" "$_msg" >&2

    if [ -n "${BASE:-}" ]; then
        _log="${BASE}/logs/noemap.log"
        # Rotate at ~200 KB (best-effort; never abort on log failure)
        _log_size=0
        if [ -f "$_log" ]; then
            _log_size="$(wc -c < "$_log" 2>/dev/null || printf '0')"
        fi
        if [ "$_log_size" -gt 204800 ]; then
            mv -f "$_log" "${_log}.1" 2>/dev/null || true
        fi
        printf '%s [%s] %s\n' "$_ts" "$_lvl" "$_msg" >> "$_log" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Command availability
# ---------------------------------------------------------------------------

# has_cmd cmd — returns 0 if cmd is on PATH, 1 otherwise. No output.
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# _spin_wait pid msg — show a cyan spinner with elapsed seconds while pid
# runs. No-op decoration when stderr is not a TTY (keeps logs/pipes clean).
_spin_wait() {
    _sw_pid="$1"; _sw_msg="${2:-working}"
    if [ ! -t 2 ]; then wait "$_sw_pid" 2>/dev/null; return $?; fi
    _sw_cyan=''; _sw_reset=''
    if [ -z "${NO_COLOR:-}" ]; then _sw_cyan='\033[0;36m'; _sw_reset='\033[0m'; fi
    _sw_frames='|/-\\'; _sw_i=0; _sw_t=0
    while kill -0 "$_sw_pid" 2>/dev/null; do
        _sw_c="$(printf '%s' "$_sw_frames" | cut -c $(( (_sw_i % 4) + 1 )))"
        printf '\r%b[%s]%b %s... %ss ' "$_sw_cyan" "$_sw_c" "$_sw_reset" "$_sw_msg" "$_sw_t" >&2
        _sw_i=$(( _sw_i + 1 )); sleep 1; _sw_t=$(( _sw_t + 1 ))
    done
    wait "$_sw_pid" 2>/dev/null; _sw_rc=$?
    printf '\r%*s\r' 60 '' >&2
    return $_sw_rc
}

# require_cmd cmd — exits with ERROR if cmd is missing.
require_cmd() {
    has_cmd "$1" || {
        log ERROR "missing hard dependency: $1 — install it first"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Session-scoped temp directory
# ---------------------------------------------------------------------------

SESSION_TMP_DIR=""

# init_session — creates session temp dir. Must be called once from the
# top-level script. Idempotent if SESSION_TMP_DIR already set and valid.
init_session() {
    if [ -n "$SESSION_TMP_DIR" ] && [ -d "$SESSION_TMP_DIR" ]; then
        return 0
    fi
    SESSION_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/noemap.XXXXXX")" || {
        log ERROR "cannot create session temp dir in ${TMPDIR:-/tmp}"
        exit 1
    }
    trap 'cleanup_session' EXIT
    trap 'cleanup_session; trap - INT;  kill -INT  "$$"' INT
    trap 'cleanup_session; trap - TERM; kill -TERM "$$"' TERM
}

# cleanup_session — removes the session temp dir.
cleanup_session() {
    if [ -n "$SESSION_TMP_DIR" ] && [ -d "$SESSION_TMP_DIR" ]; then
        rm -rf "$SESSION_TMP_DIR"
    fi
    SESSION_TMP_DIR=""
}

# session_tmp suffix — prints a temp-file path inside the session dir.
session_tmp() {
    printf '%s/%s\n' "$SESSION_TMP_DIR" "${1:-tmp}"
}

# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------

# atomic_write target — reads stdin, writes to target atomically.
# Refuses to write empty content (leaves target intact).
atomic_write() {
    _target="$1"
    _dir="$(dirname "$_target")"
    _tmp="${_dir}/.noemap_tmp.$(basename "$_target").$$"

    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }

    if [ ! -s "$_tmp" ]; then
        rm -f "$_tmp"
        log WARN "atomic_write: empty content — target left intact: $_target"
        return 1
    fi

    mv -f "$_tmp" "$_target" || {
        rm -f "$_tmp"
        log ERROR "atomic_write: mv failed for $_target"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------

ensure_dirs() {
    mkdir -p \
        "$BASE/state" \
        "$BASE/logs"  \
        "$BASE/config" \
        "$BASE/tmp"

    # ssh_config points UserKnownHostsFile here; dir must exist before
    # the first SSH connection or OpenSSH refuses to write the file.
    mkdir -p "$HOME/.local/share/noemap"
    chmod 700 "$HOME/.local/share/noemap"
    # seed devices.db from template on fresh installs (template is versioned)
    if [ ! -f "$BASE/state/devices.db" ] && [ -f "$BASE/state/devices.db.example" ]; then
        cp "$BASE/state/devices.db.example" "$BASE/state/devices.db"
    fi
}

# ---------------------------------------------------------------------------
# Env validation — hard and soft dependencies
# ---------------------------------------------------------------------------

validate_env() {
    for _cmd in awk sed grep cut ping ssh; do
        require_cmd "$_cmd"
    done

    # nmap: strongly recommended; scan.sh falls back to nc if missing
    if ! has_cmd nmap; then
        log WARN "nmap not found — host discovery will use nc fallback (port 22 only)"
        log WARN "install nmap for full, reliable discovery"
    fi

    # scp: soft dep — some environments are sftp-only
    if ! has_cmd scp; then
        log WARN "scp not found — nscp will not work; sftp-only environment?"
    fi

    # ip or ifconfig is required for interface detection
    if ! has_cmd ip && ! has_cmd ifconfig; then
        log ERROR "missing hard dependency: ip or ifconfig — install iproute2 or net-tools"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Portability helpers
# ---------------------------------------------------------------------------

safe_timeout() {
    _sec="$1"
    shift
    if has_cmd timeout; then
        timeout "$_sec" "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# known_hosts hygiene
# ---------------------------------------------------------------------------
KNOWN_HOSTS="$HOME/.local/share/noemap/known_hosts"

# known_hosts_remove_ip ip — removes all entries for an IP from known_hosts.
# Safe to call if known_hosts does not exist yet.
known_hosts_remove_ip() {
    _ip="$1"
    [ -f "$KNOWN_HOSTS" ] || return 0
    if has_cmd ssh-keygen; then
        ssh-keygen -R "$_ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    else
        _kh_tmp="${KNOWN_HOSTS}.noemap_tmp.$$"
        grep -v "^${_ip}[ ,]" "$KNOWN_HOSTS" > "$_kh_tmp" 2>/dev/null || true
        mv -f "$_kh_tmp" "$KNOWN_HOSTS" 2>/dev/null || rm -f "$_kh_tmp"
    fi
    log INFO "known_hosts: removed stale entries for $_ip"
}

# known_hosts_sync_device alias old_ip new_ip — cleans old IP entry when
# a device's IP changes so SSH does not reject the new fingerprint.
known_hosts_sync_device() {
    _alias="$1"
    _old_ip="$2"
    _new_ip="$3"
    if [ "$_old_ip" != "$_new_ip" ]; then
        log INFO "device '$_alias' IP changed: $_old_ip → $_new_ip — cleaning known_hosts"
        known_hosts_remove_ip "$_old_ip"
    fi
}

# known_hosts_prune db_path — removes known_hosts entries for IPs no longer
# in devices.db. Prevents accumulation of DHCP ghost entries.
# Only acts on plain-text (non-hashed) IPv4 entries.
known_hosts_prune() {
    _db="$1"
    [ -f "$KNOWN_HOSTS" ] || return 0
    [ -f "$_db" ]         || return 0

    _live_ips="$(awk -F'|' '
        /^[[:space:]]*$/ { next }
        /^#/             { next }
        NF >= 2          { print $2 }
    ' "$_db" 2>/dev/null)"

    _kh_tmp="${KNOWN_HOSTS}.prune_tmp.$$"
    : > "$_kh_tmp"
    while IFS= read -r _line; do
        case "$_line" in
            ''|'#'*) printf '%s\n' "$_line" >> "$_kh_tmp"; continue ;;
        esac
        _entry_host="${_line%% *}"
        case "$_entry_host" in
            [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                _found=0
                for _lip in $_live_ips; do
                    [ "$_lip" = "$_entry_host" ] && { _found=1; break; }
                done
                [ "$_found" -eq 1 ] && printf '%s\n' "$_line" >> "$_kh_tmp"
                ;;
            *)
                printf '%s\n' "$_line" >> "$_kh_tmp"
                ;;
        esac
    done < "$KNOWN_HOSTS"

    if [ -f "$_kh_tmp" ]; then
        mv -f "$_kh_tmp" "$KNOWN_HOSTS"
        log INFO "known_hosts: pruned stale entries"
    fi
}
