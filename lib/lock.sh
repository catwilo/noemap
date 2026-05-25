#!/bin/sh
# lock.sh — session-scoped exclusive lock for noemap
#
# Design:
#   • Lock dir lives under BASE/tmp (session-local, not system /tmp).
#   • Lock dir stores PID for stale-lock detection from crashed runs.
#   • acquire_lock detects stale locks (process gone) and cleans them.
#   • release_lock is called by cleanup_session — not directly by callers.
#   • mkdir(1) is atomic on POSIX local filesystems; used as the primitive.

_LOCK_DIR=""
_LOCK_PID_FILE=""

acquire_lock() {
    _LOCK_DIR="$BASE/tmp/noemap.lock"
    _LOCK_PID_FILE="$_LOCK_DIR/pid"

    # Stale lock recovery: lock dir exists but PID is gone
    if [ -d "$_LOCK_DIR" ]; then
        _existing_pid=""
        if [ -f "$_LOCK_PID_FILE" ]; then
            _existing_pid="$(cat "$_LOCK_PID_FILE" 2>/dev/null || true)"
        fi

        _stale=0
        if [ -z "$_existing_pid" ]; then
            _stale=1
        elif ! kill -0 "$_existing_pid" 2>/dev/null; then
            _stale=1
        fi

        if [ "$_stale" -eq 1 ]; then
            log WARN "stale lock found (pid=${_existing_pid:-unknown}), recovering"
            rm -rf "$_LOCK_DIR"
        fi
    fi

    # Atomic acquisition via mkdir
    if ! mkdir "$_LOCK_DIR" 2>/dev/null; then
        _running_pid="$(cat "$_LOCK_PID_FILE" 2>/dev/null || printf 'unknown')"
        log ERROR "noemap is already running (pid=$_running_pid)"
        exit 1
    fi

    printf '%s\n' "$$" > "$_LOCK_PID_FILE" || {
        log WARN "could not write PID to lock dir"
    }
}

# release_lock — removes the lock directory. Idempotent.
release_lock() {
    if [ -n "$_LOCK_DIR" ] && [ -d "$_LOCK_DIR" ]; then
        rm -rf "$_LOCK_DIR"
    fi
    _LOCK_DIR=""
    _LOCK_PID_FILE=""
}
