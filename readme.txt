
  noemap — network discovery and SSH device mapper
  ─────────────────────────────────────────────────────────────────────

  DISCOVERY

    noemap                 Fast scan: find SSH hosts on ports 22/8022/2222.
                           Validates registered hosts first via ping.
                           Displays results, then prompts to register new hosts.

    noemap --deep          Same scan + SSH banner grab (nmap -sV) to distinguish
                           Termux/Android from Debian/Ubuntu on port 22.
                           Slower but more accurate OS type detection.

    noemap --ports         Show all probed ports per host in the results table.

    noemap --deep --ports  Combine both flags.

  ─────────────────────────────────────────────────────────────────────

  CONNECT

    nssh <alias>                    Open interactive SSH session.
    nssh <alias> <cmd> [args...]    Run command remotely, print output.

      nssh deb                      # interactive shell
      nssh deb uname -a             # single command -> stdout
      nssh deb 'df -h | head -5'   # piped command (quote it)

  ─────────────────────────────────────────────────────────────────────

  TRANSFER

    nscp <alias>:/remote/path ./local/    Copy from remote to local.
    nscp ./local/file <alias>:/remote/    Copy from local to remote.

    nclip <alias>:/remote/path            Copy remote file content to clipboard
                                          (requires clipso / xclip / pbcopy).

  ─────────────────────────────────────────────────────────────────────

  CLIP (clipboard forwarding, tmux-backed)

    nclip-listen start                    Start local listener (Unix socket,
                                          tmux session "nclip-listen").
    nclip-listen stop                     Stop listener, remove socket.
    nclip-listen restart                  stop + start.
    nclip-listen status                   Show running state and socket path.
    nclip-listen foreground               Run accept-loop in foreground
                                          (for launchd/systemd KeepAlive).

    nclip-listen start-tcp                Start TCP listener (tmux session
                                          "nclip-listen-tcp", requires ncat).
    nclip-listen stop-tcp                 Stop TCP listener.
    nclip-listen restart-tcp              stop-tcp + start-tcp.
    nclip-listen status-tcp               Show TCP listener state.

    nclip-set <src> <dst>                 Define clipboard direction (src sends,
                                          dst receives). Starts nclip-listen
                                          start-tcp on dst, then runs a
                                          smoke-test send+read to confirm.
    nclip-set status                      Show current direction config.
    nclip-set clear                       Stop listener on dst, remove config.

                                          Direction is explicit, not inferred
                                          from ssh initiator. Not persisted
                                          across reboots -- re-run per session.

  ─────────────────────────────────────────────────────────────────────

  DEVICE MANAGEMENT  (ndevs)

    ndevs                              List all registered devices.
    ndevs --edit <alias>               Edit alias / IP / user / port.
    ndevs --rename <old> <new>         Rename alias.
    ndevs --remove <alias> [alias...]  Remove one or more devices.
    ndevs --update-ip <alias> <ip>     Update IP, auto-clean known_hosts.
    ndevs --resetall                   Wipe devices.db + known_hosts + hosts.db + cache.

  ─────────────────────────────────────────────────────────────────────

  NOTES

    • Aliases are short names you assign during registration (deb, cel, pi ...).
    • All tools resolve aliases from  $NOEMAP_BASE/state/devices.db
    • SSH config lives at            $NOEMAP_BASE/config/ssh_config
    • known_hosts lives at           ~/.local/share/noemap/known_hosts
    • Logs at                        $NOEMAP_BASE/logs/noemap.log

    • On each run: registered hosts are pinged first. Non-responding hosts
      are removed automatically. Responding hosts skip the full scan.

    • Fast mode:  type detection = port only (8022->android, 22/2222->linux).
                  No nmap -sV, no banner grab. Safe and quick on Termux.
    • Deep mode:  adds banner grab on port 22 to tell Termux apart from
                  a real Debian/Ubuntu sshd. Use when type matters.

