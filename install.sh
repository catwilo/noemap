#!/bin/sh
# install.sh  noemap installer (symlink model)
#
# Symlinks tools, libs, and managed config files directly from the repo
# checkout, so updates to these files (code, ssh_config) are reflected
# immediately without re-running install.sh. The repo must remain present
# at the checked-out path; deleting it will break the installation.
#
#   Termux : symlink bin/* → $PREFIX/bin, lib/* → ~/.local/share/noemap/lib
#   Debian : symlink bin/* → ~/.local/bin, lib/* → ~/.local/share/noemap/lib
#   config : symlink config/ssh_config → ~/.local/share/noemap/config/ssh_config
#   state  : real files (devices.db, cache.env) remain in ~/.local/share/noemap/state
#
# Usage:
#   sh install.sh                     -- install/update noemap (idempotent)
#   sh install.sh client-setup <host> -- emit CLIENT clipboard setup script
#   sh install.sh -h | --help         -- show this help
#
# Idempotent: safe to re-run. state/devices.db stays user-owned, never overwritten.


set -eu

log()  { printf '[%s] %s\n' "$1" "$2"; }
fail() { log ERROR "$1"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_usage() {
    cat <<USAGE
usage: install.sh [command]

commands:
  (none)              install/update noemap (idempotent, default)
  client-setup <host> emit a script to configure the SSH CLIENT clipboard
  -h, --help          show this help
USAGE
}

# ---------------------------------------------------------------------------
# client-setup -- emit a script to configure the SSH CLIENT (Mac/Termux) so the
# server's clipboard socket forwards into the client's native clipboard.
# ---------------------------------------------------------------------------
_do_client_setup() {
    _srv_sock="$HOME/.local/share/noemap/clip.sock"
    cat <<'CLIENTEOF'
#!/usr/bin/env bash
# noemap client clipboard setup -- run ON YOUR Mac or Termux.
# Auto-detects OS: macOS -> LaunchAgent (pbsync); else -> background listener.
# Adds a RemoteForward so the server socket pipes into your local clipboard.
set -eu
SERVER_HOST="${1:-}"
[ -n "$SERVER_HOST" ] || { echo "usage: bash this.sh <ssh-host-or-alias>"; exit 1; }
SSH_CONF="$HOME/.ssh/config"
mkdir -p "$HOME/.local/bin"

if [ "$(uname)" = "Darwin" ]; then
  LOCAL_SOCK="$HOME/.clipd.sock"
  cat > "$HOME/.local/bin/pbsync" <<'PBS'
#!/bin/bash
SOCK="$HOME/.clipd.sock"
rm -f "$SOCK"
exec nc -lU "$SOCK" | pbcopy
PBS
  chmod +x "$HOME/.local/bin/pbsync"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/io.clipd.agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.clipd.agent</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/.local/bin/pbsync</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
  launchctl unload "$HOME/Library/LaunchAgents/io.clipd.agent.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/io.clipd.agent.plist"
  echo "macOS: LaunchAgent io.clipd.agent cargado"
else
  LOCAL_SOCK="$HOME/.local/share/noemap/clip.sock"
  if command -v termux-clipboard-set >/dev/null 2>&1; then CLIP_CMD=termux-clipboard-set
  elif command -v wl-copy >/dev/null 2>&1; then CLIP_CMD=wl-copy
  elif command -v xclip >/dev/null 2>&1; then CLIP_CMD="xclip -selection clipboard"
  else echo "no clipboard tool found"; exit 1; fi
  cat > "$HOME/.local/bin/noemap-clip-listener" <<LISTENER
#!/usr/bin/env bash
SOCK="$LOCAL_SOCK"
rm -f "\$SOCK"
while true; do nc -lU "\$SOCK" 2>/dev/null | $CLIP_CMD || true; done
LISTENER
  chmod +x "$HOME/.local/bin/noemap-clip-listener"
  echo "Linux/Termux: inicia el listener: ~/.local/bin/noemap-clip-listener &"
fi

touch "$SSH_CONF"; chmod 600 "$SSH_CONF"
BEG="# >>> noemap-clip $SERVER_HOST >>>"
END="# <<< noemap-clip $SERVER_HOST <<<"
TMP="$(mktemp)"
awk -v b="$BEG" -v e="$END" '$0==b{s=1} s&&$0==e{s=0;next} !s{print}' "$SSH_CONF" > "$TMP"
{
  cat "$TMP"
  echo "$BEG"
  echo "Host $SERVER_HOST"
  echo "    RemoteForward /home/u/.local/share/noemap/clip.sock $LOCAL_SOCK"
  echo "$END"
} > "$SSH_CONF"
rm -f "$TMP"
echo "Listo. Reconecta SSH para crear el socket en el servidor."
CLIENTEOF
}

# ---------------------------------------------------------------------------
# install -- full idempotent install/update (default command)
# ---------------------------------------------------------------------------
_do_install() {

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
# Registry bootstrap (noemap identity/hostkey trust -- load-bearing, hard-fail)
#   Clones the git-backed master registry so this node can read cloud-
#   registered node identities/hostkeys. Without it, node_alias()/
#   registry_row_by_hostkey() silently degrade to empty (identity.sh),
#   causing spurious alias prompts and password fallback instead of
#   hostkey-based trust. Idempotent: skipped if already cloned.
# ---------------------------------------------------------------------------
REGISTRY_DIR="$HOME/.noemap-registry"
if [ ! -d "$REGISTRY_DIR/.git" ]; then
    log INFO "cloning noemap registry..."
    git clone git@github.com:catwilo/noemap-registry.git "$REGISTRY_DIR" \
        || fail "registry clone failed -- noemap requires it for identity/hostkey trust. Run manually: git clone git@github.com:catwilo/noemap-registry.git $REGISTRY_DIR"
    log OK "registry cloned: $REGISTRY_DIR"
else
    log INFO "registry already cloned: $REGISTRY_DIR"
fi
# ---------------------------------------------------------------------------
# Symlink libs to the shared dir (source of truth stays the repo)
# ---------------------------------------------------------------------------
for _l in "$SCRIPT_DIR"/lib/*.sh; do
    [ -f "$_l" ] || continue
    ln -sf "$_l" "$LIBDIR/$(basename "$_l")"
done
log INFO "libs linked"

# ---------------------------------------------------------------------------
# Symlink readme.txt (help text, read at runtime by _print_help)
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/readme.txt" ]; then
    ln -sf "$SCRIPT_DIR/readme.txt" "$DATADIR/readme.txt"
    log INFO "readme.txt linked"
else
    log WARN "readme.txt not found in repo -- noemap -h will fail until present"
fi

# ---------------------------------------------------------------------------
# Symlink tools to BINDIR (executable bit already set in the repo)
# ---------------------------------------------------------------------------
for _b in "$SCRIPT_DIR"/bin/*; do
    [ -f "$_b" ] || continue
    _name="$(basename "$_b")"
    case "$_name" in *.bak) continue ;; esac
    ln -sf "$_b" "$BINDIR/$_name"
done
log INFO "tools linked"

# ---------------------------------------------------------------------------
# Seed user data (never overwrite existing)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Symlink managed config (Include ~/.ssh/config in ssh_config already
# covers per-user overrides, so the file itself stays fully repo-managed).
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/config/ssh_config" ]; then
    ln -sf "$SCRIPT_DIR/config/ssh_config" "$CFGDIR/ssh_config"
    log INFO "ssh_config linked"
fi

if [ ! -f "$STATEDIR/devices.db" ]; then
    : > "$STATEDIR/devices.db"
    log INFO "devices.db initialised (empty)"
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
has nmap || {
    log WARN "nmap not found  attempting to install..."

    _nmap_cmd=""
    if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/bin" ]; then
        _nmap_cmd="pkg install -y nmap"
    elif has apt-get; then
        _nmap_cmd="sudo apt-get install -y nmap"
    fi

    if [ -n "$_nmap_cmd" ]; then
        if eval "$_nmap_cmd" 2>/dev/null; then
            log OK "nmap installed"
        else
            fail "nmap install failed -- noemap requires nmap. Run manually: $_nmap_cmd"
        fi
    else
        fail "nmap not found and no package manager detected. Install nmap manually and re-run."
    fi

    # Verify nmap is now available
    has nmap || fail "nmap still not found after install attempt"
}
has scp   || log WARN "scp not found  nscp unavailable"
has ncat || {
    log WARN "ncat not found  nclip TCP listener unavailable"

    _ncat_cmd=""
    if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/bin" ]; then
        _ncat_cmd="pkg install -y ncat"
    elif has apt-get; then
        _ncat_cmd="sudo apt-get install -y ncat"
    fi
    if [ -n "$_ncat_cmd" ]; then
        if [ -t 0 ]; then
            printf 'install ncat now? [y/N] '
            read -r _ncat_ans
            case "$_ncat_ans" in
                y|Y) eval "$_ncat_cmd" && log OK "ncat installed" || log WARN "ncat install failed -- run manually: $_ncat_cmd" ;;
                *) log INFO "skipping ncat install" ;;
            esac
        else
            log INFO "non-interactive  skipping ncat install, run manually: $_ncat_cmd"
        fi
    fi
}

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
# SSH key bootstrap (noemap#15)
#   1. Generate ~/.ssh/id_ed25519 (no passphrase) if missing -- required for
#      non-interactive nssh between nodes. No passphrase by design: these keys
#      are used by automation, an agent prompt would break the unattended flow.
#   2. Distribute our public key to every node reachable WITHOUT a password
#      (reuse the already-trusted SSH channel). Idempotent append to the
#      remote authorized_keys -- never duplicates.
#   3. For nodes not yet reachable passwordless, print the exact ssh-copy-id
#      command to run once (first-time bootstrap of a new node).
#   4. Verify the handshake to each node and report OK / needs-setup.
# ---------------------------------------------------------------------------
ssh_key_bootstrap() {
    # Internal calls: never prompt for a password, fail fast instead
    # (ssh_config's automation Match block enforces BatchMode yes here).
    export NOEMAP_SSH_ROLE=automation

    _key="$HOME/.ssh/id_ed25519"
    _pub="$_key.pub"

    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$_key" ]; then
        if has ssh-keygen; then
            ssh-keygen -t ed25519 -N "" -f "$_key" -C "noemap@$(hostname 2>/dev/null || echo node)" >/dev/null 2>&1 \
                && log OK "generated ssh key: $_key" \
                || { log WARN "ssh-keygen failed -- skipping key bootstrap"; return 0; }
        else
            log WARN "ssh-keygen not found -- skipping key bootstrap"; return 0
        fi
    else
        log INFO "ssh key already present: $_key"
    fi
    chmod 600 "$_key" 2>/dev/null || true
    [ -f "$_pub" ] || { log WARN "no public key at $_pub -- skipping distribution"; return 0; }

    _devdb="$STATEDIR/devices.db"
    [ -f "$_devdb" ] && [ -s "$_devdb" ] || { log INFO "no nodes registered -- key distribution skipped"; return 0; }
    has "$BINDIR/nssh" || command -v nssh >/dev/null 2>&1 || { log INFO "nssh unavailable -- key distribution skipped"; return 0; }

    # blockdb.sh must load before identity.sh, which calls blockdb_get/
    # blockdb_field internally.
    if [ -f "$LIBDIR/blockdb.sh" ]; then
        # shellcheck source=/dev/null
        . "$LIBDIR/blockdb.sh"
    fi
    # Load is_local_ip so we never try to SSH into ourselves (local IPs are
    # dynamic/router-assigned; enumerated live via ifconfig in identity.sh).
    if [ -f "$LIBDIR/identity.sh" ]; then
        # shellcheck source=/dev/null
        . "$LIBDIR/identity.sh"
    fi

    _pubdata="$(cat "$_pub")"
    _need_manual=""
    # iterate registered aliases (skip self handled by nssh/devices content)
    _skb_aliases1="$(blockdb_list "$_devdb" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ')"
    while IFS= read -r _ka; do
        [ -n "$_ka" ] || continue
        _skb_blk1="$(blockdb_get "$_devdb" alias "$_ka")"
        [ -n "$_skb_blk1" ] || continue
        _kip="$(blockdb_field "$_skb_blk1" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_kip"; then continue; fi
        # reachable passwordless? (BatchMode: never prompts)
        if nssh "$_ka" "true" </dev/null >/dev/null 2>&1; then
            # idempotent append: only add if not already present
            nssh "$_ka" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$_pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$_pubdata' >> ~/.ssh/authorized_keys" </dev/null >/dev/null 2>&1 \
                && log OK "key ensured on $_ka" \
                || log WARN "key append to $_ka failed"
        else
            _need_manual="$_need_manual $_ka"
        fi
    done <<EOF_SKB1
$_skb_aliases1
EOF_SKB1

    if [ -n "$_need_manual" ]; then
        log WARN "nodes needing first-time key setup:$_need_manual"
        for _m in $_need_manual; do
            printf '    run once:  ssh-copy-id -i %s %s\n' "$_pub" "$_m"
        done
    fi

    # final handshake verification
    _skb_aliases2="$(blockdb_list "$_devdb" | awk '
        BEGIN { RS=""; FS="\n" }
        {
            for (i = 1; i <= NF; i++) {
                colon = index($i, ":")
                if (colon == 0) continue
                fk = substr($i, 1, colon - 1)
                if (fk == "alias") { print substr($i, colon + 2); break }
            }
        }
    ')"
    while IFS= read -r _ka; do
        [ -n "$_ka" ] || continue
        _skb_blk2="$(blockdb_get "$_devdb" alias "$_ka")"
        [ -n "$_skb_blk2" ] || continue
        _kip="$(blockdb_field "$_skb_blk2" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_kip"; then continue; fi
        if nssh "$_ka" "true" </dev/null >/dev/null 2>&1; then
            log OK "handshake $_ka: OK"
        else
            log WARN "handshake $_ka: needs setup"
        fi
    done <<EOF_SKB2
$_skb_aliases2
EOF_SKB2
}
ssh_key_bootstrap

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

}

# ---------------------------------------------------------------------------
# Top-level dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    -h|--help)
        _usage
        exit 0
        ;;
    client-setup)
        shift
        _do_client_setup "$@"
        ;;
    "")
        _do_install
        ;;
    *)
        log ERROR "unknown command: $1"
        _usage
        exit 1
        ;;
esac
