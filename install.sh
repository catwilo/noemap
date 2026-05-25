#!/bin/sh
# install.sh — noemap installer
#
# Autodetects shell rc, copies files, makes binaries executable,
# patches PATH + aliases into your shell rc.
# After running: source ~/.zshrc (or ~/.bashrc) and you're done.
#
# Usage:
#   sh install.sh
#   NOEMAP_BASE=~/tools/noemap sh install.sh   # custom location
#
# Idempotent: safe to re-run. state/devices.db and config/ssh_config
# are never overwritten (user data preserved).

set -eu

log()  { printf '[%s] %s\n' "$1" "$2"; }
fail() { log ERROR "$1"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="${NOEMAP_BASE:-$HOME/dev/noemap}"
log INFO "installing to: $BASE"

# ---------------------------------------------------------------------------
# Detect shell rc
# ---------------------------------------------------------------------------
DETECTED_SHELL=""
RC_FILE=""

if has zsh; then DETECTED_SHELL=zsh; RC_FILE="$HOME/.zshrc"; \
elif has bash; then DETECTED_SHELL=bash; RC_FILE="$HOME/.bashrc"; \
else DETECTED_SHELL=sh; RC_FILE="$HOME/.profile"; fi

case "${SHELL:-}" in
    */zsh)  DETECTED_SHELL=zsh;  RC_FILE="$HOME/.zshrc"  ;;
    */bash) DETECTED_SHELL=bash; RC_FILE="$HOME/.bashrc" ;;
esac

log INFO "detected shell: $DETECTED_SHELL  rc: $RC_FILE"

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
mkdir -p "$BASE/bin" "$BASE/lib" "$BASE/config" "$BASE/state" "$BASE/logs" "$BASE/tmp"
mkdir -p "$HOME/.local/share/noemap"
chmod 700 "$HOME/.local/share/noemap"

# ---------------------------------------------------------------------------
# Copy files
# ---------------------------------------------------------------------------
_copy() {
    _src="$SCRIPT_DIR/$1"
    _dst="$BASE/$1"
    if [ -f "$_src" ]; then cp "$_src" "$_dst"; \
    else log WARN "source not found, skipping: $1"; fi
}

for _b in "$SCRIPT_DIR"/bin/*; do [ -f "$_b" ] || continue; _name="$(basename "$_b")"; _copy "bin/$_name"; done
for _l in lib/util.sh lib/lock.sh lib/iface.sh lib/cache.sh lib/scan.sh \
          lib/fingerprint.sh lib/output.sh lib/devices.sh; do _copy "$_l"; done

# Preserve existing user files
if [ ! -f "$BASE/config/ssh_config" ]; then
    _copy "config/ssh_config"; log INFO "ssh_config installed"
else
    log INFO "config/ssh_config already exists — left intact"
fi

if [ ! -f "$BASE/state/devices.db" ]; then
    _copy "state/devices.db"; log INFO "devices.db initialised"
else
    log INFO "state/devices.db already exists — left intact"
fi

# Always clear cache on install (stale IPs are wrong after reinstall)
printf '' > "$BASE/state/cache.env"
log INFO "cache cleared"

# ---------------------------------------------------------------------------
# Make binaries executable
# ---------------------------------------------------------------------------
for _b in "$BASE"/bin/*; do [ -f "$_b" ] && chmod +x "$_b"; done
log INFO "binaries marked executable"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
log INFO "checking dependencies..."
_missing=""
for _cmd in awk sed grep cut ping ssh; do
    has "$_cmd" || _missing="$_missing $_cmd"
done
if ! has ip && ! has ifconfig; then _missing="$_missing ip/ifconfig"; fi
[ -z "$_missing" ] || log WARN "MISSING hard deps:$_missing — noemap will not work"

has nmap  || log WARN "nmap not found — discovery will use nc fallback (port 22 only)"
has scp   || log WARN "scp not found — nscp unavailable"
has rsync || log WARN "rsync not found — nrsync unavailable"

# ---------------------------------------------------------------------------
# Patch shell rc — guarded, idempotent
# ---------------------------------------------------------------------------
MARKER="# >>> noemap"

if grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
    log INFO "rc already patched: $RC_FILE — skipping"
else
    [ -f "$RC_FILE" ] || touch "$RC_FILE"
    cat >> "$RC_FILE" << RC_BLOCK

$MARKER
export NOEMAP_BASE="$BASE"
export PATH="\$PATH:$BASE/bin"
alias nm='noemap'
alias nd='ndevs'
# <<< noemap
RC_BLOCK
    log OK "patched: $RC_FILE"
fi

# ---------------------------------------------------------------------------
# clipso — install by default from ~/scripts/clipso/clipso.sh
# ---------------------------------------------------------------------------
CLIPSO_SCRIPT="${HOME}/scripts/clipso/clipso.sh"
CLIPSO_INSTALL="${HOME}/scripts/clipso/install.sh"
if [ -f "$CLIPSO_INSTALL" ]; then
    log INFO "installing clipso..."
    bash "$CLIPSO_INSTALL"
elif [ -f "$CLIPSO_SCRIPT" ]; then
    log WARN "clipso install.sh not found — add manually: $CLIPSO_INSTALL"
else
    log WARN "clipso not found at $CLIPSO_SCRIPT — clipboard features unavailable"
fi

# ---------------------------------------------------------------------------
# Termux client setup — wire RemoteForward for clipboard forward
# ---------------------------------------------------------------------------
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/bin" ]; then
    # Running on Termux (client) — configure client-setup for all known devices
    if [ -f "$BASE/state/devices.db" ]; then
        while IFS="|" read -r _alias _ip _user _port || [ -n "$_alias" ]; do
            case "$_alias" in "#"*|"") continue ;; esac
            [ -n "$_user" ] && [ -n "$_ip" ] || continue
            _port="${_port:-22}"
            _srv_sock="/home/${_user}/.local/share/noemap/clip.sock"
            _loc_sock="${HOME}/.noemap-clip.sock"
            _beg="# >>> noemap-clip ${_alias} >>>"
            _end="# <<< noemap-clip ${_alias} <<<"
            _rc="${HOME}/.ssh/config"
            touch "$_rc"; chmod 600 "$_rc"
            _tmp="$(mktemp "${TMPDIR:-/tmp}/noemap-ssh.XXXXXX")"
            awk -v b="$_beg" -v e="$_end"                 '$0==b{s=1} s&&$0==e{s=0;next} !s{print}' "$_rc" > "$_tmp"
            {
                cat "$_tmp"
                printf '%s
' "$_beg"
                printf 'Host %s
' "$_alias"
                printf '    RemoteForward %s %s
' "$_srv_sock" "$_loc_sock"
                printf '%s
' "$_end"
            } > "$_rc"
            rm -f "$_tmp"
            log INFO "RemoteForward wired for alias: ${_alias}"
        done < "$BASE/state/devices.db"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf '\n'
log OK "noemap installed → $BASE"
printf '\n'
printf '  Next:    source %s\n' "$RC_FILE"
printf '  Run:     noemap\n'
printf '  Devices: ndevs\n'
printf '  Edit:    ndevs --edit <alias>\n'
printf '  Help:    ndevs --help\n'
printf '\n'
