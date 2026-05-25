# noemap

Network discovery and SSH device mapper for LAN environments. Scans for
SSH-reachable hosts, registers them under short aliases, and provides
alias-aware wrappers around ssh, scp, rsync, and clipboard copy.

Targets: Debian 13 and Termux (non-root). Shell: POSIX sh for tools,
zsh for the capture hook.

## Install

    noemap install

Idempotent. Symlinks `bin/*` into `~/.local/bin` (or `$PREFIX/bin` on
Termux) and writes a delimited block to `~/.zshrc` (PATH fallback,
the `clipc` helper, and the one-shot `ncssh` capture loader). Re-running
overwrites the previous block cleanly.

## Commands

All commands accept `-h` for usage.

- `noemap` — fast scan for SSH hosts, then prompt to register new ones.
  - `--deep` adds OS detection via SSH banner; `--ports` shows open ports.
  - `-i <iface>` forces the network interface (otherwise derived from the
    default route).
- `ndevs` — manage the device database (edit, rename, remove, update-ip,
  resetall).
- `nssh <alias> [cmd...]` — SSH to an alias; forwards an optional command.
- `ncssh <alias> [cmd...]` — like nssh, but the last command's output is
  mirrored to the clipboard (server-local and the client terminal via
  OSC52, through clipso).
- `nscp [-r] <src> <dst>` — scp using aliases; `alias:/path` for remote.
- `nrsync <src> <dst>` — rsync using aliases; `alias:/path` for remote.
- `nclip <alias:/path>` — copy a remote file to the clipboard via clipso.

## Interface selection

On multi-homed hosts, the scan interface is derived from the default
route, not the first interface the kernel lists. Override with
`noemap -i <iface>`.

## ncssh capture

`ncssh` exports `LC_NCSSH=1`, forwarded over SSH (relies on the server's
`AcceptEnv LC_*`). The server's `~/.zshrc` sources `lib/capture.zsh` only
when that variable is set, so plain `nssh` sessions carry no overhead.
The hook copies the last command's stdout (or `.` if empty) on each
prompt, keeping output visible on the terminal.

## Layout

    bin/     command-line tools
    lib/     shared helpers (devices, iface, scan, capture hook, ...)
    config/  ssh_config used by the wrappers
    state/   devices.db and cache.env
