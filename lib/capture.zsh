# capture.zsh — noemap ncssh output-capture hook (zsh only)
#
# Loaded one-shot by the server's ~/.zshrc when ~/.noemap-capture exists.
# Mirrors the LAST command's stdout to the clipboard via clipso, which itself
# copies to the local clipboard AND to the client terminal over OSC52.

[[ -o interactive ]] || return 0
command -v clipso >/dev/null 2>&1 || return 0

_NCAP_BUF="${TMPDIR:-/tmp}/noemap-capture.$$"
: > "$_NCAP_BUF"

exec {_NCAP_SAVED}>&1
exec 1> >(tee -a "$_NCAP_BUF"); _NCAP_TEE=$!

_ncap_preexec() { : > "$_NCAP_BUF"; }

_ncap_precmd() {
    [[ -e "$_NCAP_BUF" ]] || return 0
    sync
    local out
    out="$(sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' "$_NCAP_BUF" 2>/dev/null)"
    [[ -n "${out//[[:space:]]/}" ]] || out="."
    printf '%s' "$out" | clipso >/dev/null 2>&1 || true
}

_ncap_cleanup() {
    exec 1>&${_NCAP_SAVED} {_NCAP_SAVED}>&- 2>/dev/null
    [[ -n "${_NCAP_TEE:-}" ]] && kill "$_NCAP_TEE" 2>/dev/null
    rm -f "$_NCAP_BUF" 2>/dev/null
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _ncap_preexec
add-zsh-hook precmd  _ncap_precmd
add-zsh-hook zshexit _ncap_cleanup
