noemap — network discovery and device mapper
============================================

A lightweight, self-hosted suite for discovering and connecting to devices
on a home or lab network. Designed for Termux, Debian, and Arch Linux.
No daemon, no cloud, no dependencies beyond standard POSIX tools + nmap.


TOOLS
-----
  noemap    Discover and fingerprint hosts on the local network
  nssh      SSH to a registered device by alias
  nscp      scp wrapper with alias:/path notation
  nrsync    rsync wrapper with alias:/path notation
  ndevs     List all registered devices
  nclip     Copy a remote file to clipboard via nscp + clipso


QUICK START
-----------
  export NOEMAP_BASE=~/dev/noemap   # or add to ~/.profile

  noemap                            # discover network, auto-register hosts
  ndevs                             # list registered devices
  nssh deb                          # SSH to alias "deb"
  nscp deb:/etc/hosts ./hosts       # copy file from remote
  nrsync ./mydir/ deb:/backup/      # rsync local dir to remote


DEVICES DATABASE
----------------
File: $BASE/state/devices.db
Format (pipe-delimited, one per line):
  ALIAS|IP|USER|PORT

Example:
  deb|192.168.x.x|alice|22
  raspi|192.168.x.x|pi|22

Lines beginning with '#' are comments. noemap auto-adds a "deb" entry
for the first linux-ssh host it detects (TTL=64 + port 22 open).
Existing entries are never overwritten — your edits are always preserved.


NETWORK DETECTION
-----------------
noemap reads the actual prefix length from your interface (e.g. /22, /23)
rather than always assuming /24. nmap scans the correct CIDR range.
A warning is logged when the prefix is not /24 so you know the scan scope.

If nmap is not available, discovery falls back to a parallelised nc probe
on port 22 only (8 workers, ~30s for a /24). Install nmap for full,
reliable discovery across all host types.


CACHE
-----
Results are cached in $BASE/state/cache.env for 6 hours (configurable via
_CACHE_MAX_AGE in cache.sh). Staleness is tracked via LAST_SCAN stored in
the cache itself — no dependency on GNU stat.


LOGGING
-------
All runs append to $BASE/logs/noemap.log with timestamps. Log rotates
automatically at ~200KB (previous log kept as noemap.log.1).


SSH CONFIG
----------
$BASE/config/ssh_config is used by nssh, nscp, and nrsync.

  StrictHostKeyChecking accept-new
    Silently trusts new host keys on first connect. Suitable for trusted
    home/lab networks. Change to "yes" on untrusted networks.

  ControlMaster
    nssh uses ControlMaster=auto (multiplexing for interactive sessions).
    nscp and nrsync use ControlMaster=no to avoid hangs in non-interactive
    transfers if no master socket exists yet.

  UserKnownHostsFile
    Stored at ~/.local/share/noemap/known_hosts (created automatically).


ENVIRONMENT
-----------
  NOEMAP_BASE    Installation root (default: ~/dev/noemap)
  CLIPSO_BIN     Path to clipso binary (default: ~/scripts/clipso.sh)
  NOEMAP_SSH_ROLE  Set internally by nssh/nscp/nrsync; do not set manually


INTEGRITY
---------
SHA256SUMS contains checksums for all shipped files. To verify:
  sha256sum -c SHA256SUMS


REQUIREMENTS
------------
  Hard: sh, awk, sed, grep, cut, ping, nmap, ssh
  Soft: scp (nscp), rsync (nrsync), nc (scan fallback), timeout, clipso
  Network: ip(8) or ifconfig
