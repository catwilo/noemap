# noemap

Network discovery and SSH device mapper for LAN environments. Scans for
SSH-reachable hosts, registers them under short aliases, and provides
alias-aware wrappers around ssh, scp, rsync, and clipboard copy.

Targets: Debian 13 and Termux (non-root). Shell: POSIX sh for tools.

## Install

    noemap install

Idempotent. Symlinks `bin/*` into `~/.local/bin` (or `$PREFIX/bin` on
Termux) and writes a delimited block to `~/.zshrc` (PATH fallback).
Re-running overwrites the previous block cleanly.

## Commands

All commands accept `-h` for usage.

- `noemap` — fast scan for SSH hosts, then prompt to register new ones.
  - `--deep` adds OS detection via SSH banner; `--ports` shows open ports.
  - `-i <iface>` forces the network interface (otherwise derived from the
    default route).
- `ndevs` — manage the device database (edit, rename, remove, update-ip,
  resetall).
- `nssh <alias> [cmd...]` -- SSH to an alias; forwards an optional command.
- `nscp [-r] <src> <dst>` — scp using aliases; `alias:/path` for remote.
- `nrsync <src> <dst>` — rsync using aliases; `alias:/path` for remote.
- `nclip <alias:/path>` — copy a remote file to the clipboard via clipso.

## Interface selection

On multi-homed hosts, the scan interface is derived from the default
route, not the first interface the kernel lists. Override with
`noemap -i <iface>`.

## Layout

    bin/     command-line tools
    lib/     shared helpers (devices, iface, scan, ...)
    config/  ssh_config used by the wrappers
    state/   devices.db and cache.env
