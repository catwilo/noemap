#!/bin/sh
# install.sh  noemap installer (standalone-copy model)
#
# Copies tools to a bin dir already on PATH, and libs to a fixed shared
# dir, so the source repo can be deleted afterwards and tools still work.
#
#   Termux : tools -> $PREFIX/bin
#   Debian : tools -> ~/.local/bin
#   libs   : ~/.local/share/noemap/lib   (both platforms)
#
# Usage:
#   sh install.sh
#
# Idempotent: safe to re-run. state/devices.db and config/ssh_config in
# the shared data dir are never overwritten (user data preserved).

set -eu

log()  { printf '[%s] %s\n' "$1" "$2"; }
fail() { log ERROR "$1"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Resolve install destinations
# ---------------------------------------------------------------------------
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/bin" ]; then
    BINDIR="$PREFIX/bin"          # Termux
else
    BINDIR="$HOME/.local/bin"     # Debian / generic
fi
DATADIR="$HOME/.local/share/noemap"
LIBDIR="$DATADIR/lib"
STATEDIR="$DATADIR/state"
CFGDIR="$DATADIR/config"

log INFO "tools -> $BINDIR"
log INFO "libs  -> $LIBDIR"

mkdir -p "$BINDIR" "$LIBDIR" "$STATEDIR" "$CFGDIR" "$DATADIR/logs"
chmod 700 "$DATADIR"

# ---------------------------------------------------------------------------
# Remove stale symlinks in BINDIR that point back into any repo checkout.
# Previous installs symlinked $BINDIR/<tool> -> <repo>/bin/<tool>; those
# break the "repo is deletable" guarantee, so replace them with real copies.
# ---------------------------------------------------------------------------
for _b in "$SCRIPT_DIR"/bin/*; do
    [ -f "$_b" ] || continue
    _name="$(basename "$_b")"
    _link="$BINDIR/$_name"
    if [ -L "$_link" ]; then
        log INFO "removing stale symlink: $_link"
        rm -f "$_link"
    fi
done

# ---------------------------------------------------------------------------
# Copy libs to the shared dir (real files)
# ---------------------------------------------------------------------------
for _l in "$SCRIPT_DIR"/lib/*.sh; do
    [ -f "$_l" ] || continue
    cp "$_l" "$LIBDIR/$(basename "$_l")"
done
log INFO "libs installed"

# ---------------------------------------------------------------------------
# Copy tools to BINDIR (real files, executable)
# ---------------------------------------------------------------------------
for _b in "$SCRIPT_DIR"/bin/*; do
    [ -f "$_b" ] || continue
    _name="$(basename "$_b")"
    cp "$_b" "$BINDIR/$_name"
    chmod +x "$BINDIR/$_name"
done
log INFO "tools installed"

# ---------------------------------------------------------------------------
# Seed user data (never overwrite existing)
# ---------------------------------------------------------------------------
if [ ! -f "$CFGDIR/ssh_config" ] && [ -f "$SCRIPT_DIR/config/ssh_config" ]; then
    cp "$SCRIPT_DIR/config/ssh_config" "$CFGDIR/ssh_config"
    log INFO "ssh_config installed"
else
    log INFO "ssh_config left intact"
fi

if [ ! -f "$STATEDIR/devices.db" ] && [ -f "$SCRIPT_DIR/state/devices.db" ]; then
    cp "$SCRIPT_DIR/state/devices.db" "$STATEDIR/devices.db"
    log INFO "devices.db initialised"
else
    log INFO "devices.db left intact"
fi

: > "$STATEDIR/cache.env"
log INFO "cache cleared"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
log INFO "checking dependencies..."
_missing=""
for _cmd in awk sed grep cut ping ssh; do
    has "$_cmd" || _missing="$_missing $_cmd"
done
if ! has ip && ! has ifconfig; then _missing="$_missing ip/ifconfig"; fi
[ -z "$_missing" ] || log WARN "MISSING hard deps:$_missing  noemap will not work"
has nmap  || log WARN "nmap not found  discovery will use nc fallback"
has scp   || log WARN "scp not found  nscp unavailable"
has rsync || log WARN "rsync not found  nrsync unavailable"
has ncat  || log WARN "ncat not found  nclip TCP listener unavailable"

# ---------------------------------------------------------------------------
# Patch shell rc: export NOEMAP_DATA + aliases (PATH already covers BINDIR)
# ---------------------------------------------------------------------------
DETECTED_SHELL=sh; RC_FILE="$HOME/.profile"
if has zsh; then DETECTED_SHELL=zsh; RC_FILE="$HOME/.zshrc"
elif has bash; then DETECTED_SHELL=bash; RC_FILE="$HOME/.bashrc"; fi
case "${SHELL:-}" in
    */zsh)  DETECTED_SHELL=zsh;  RC_FILE="$HOME/.zshrc"  ;;
    */bash) DETECTED_SHELL=bash; RC_FILE="$HOME/.bashrc" ;;
esac
log INFO "shell rc: $RC_FILE"

MARKER="# >>> noemap"
if grep -qF "$MARKER" "$RC_FILE" 2>/dev/null; then
    log INFO "rc already patched  skipping"
else
    [ -f "$RC_FILE" ] || touch "$RC_FILE"
    cat >> "$RC_FILE" << RC_BLOCK

$MARKER
export NOEMAP_DATA="$DATADIR"
alias nm='noemap'
alias nd='ndevs'
# <<< noemap
RC_BLOCK
    log OK "patched: $RC_FILE"
fi

# ---------------------------------------------------------------------------
# Ensure BINDIR on PATH (only if missing; respects versioned-dotfile symlinks)
# ---------------------------------------------------------------------------
case ":$PATH:" in
    *":$BINDIR:"*) log INFO "PATH already includes $BINDIR" ;;
    *)
        if [ -L "$RC_FILE" ]; then
            log WARN "$RC_FILE is a symlink (versioned dotfile)  add manually: export PATH=\"$BINDIR:\$PATH\""
        else
            printf '\nexport PATH="%s:$PATH"  # noemap bindir\n' "$BINDIR" >> "$RC_FILE"
            log OK "added $BINDIR to PATH in $RC_FILE"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# clipso (best-effort)
# ---------------------------------------------------------------------------
CLIPSO_INSTALL="${HOME}/unix-toolkit-tools/clipso/install.sh"
if [ -f "$CLIPSO_INSTALL" ]; then
    log INFO "installing clipso..."
    bash "$CLIPSO_INSTALL" || log WARN "clipso install failed"
else
    log WARN "clipso install.sh not found  clipboard features may be limited"
fi

# ---------------------------------------------------------------------------
# Post-install verification: prove an installed tool resolves its libs.
# ---------------------------------------------------------------------------
if NOEMAP_DATA="$DATADIR" "$BINDIR/ndevs" >/dev/null 2>&1; then
    log OK "post-install check passed (ndevs runs standalone)"
else
    fail "post-install check FAILED  ndevs could not run from $BINDIR (libs at $LIBDIR?)"
fi

printf '\n'
log OK "noemap installed  tools in $BINDIR, libs in $LIBDIR"
printf '  Repo is now deletable; tools run standalone.\n'
printf '  Run: noemap   Devices: ndevs\n\n'
