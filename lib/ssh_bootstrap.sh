#!/bin/sh
# ssh_bootstrap.sh -- SSH key generation + bidirectional handshake distribution.
#
# Extracted from install.sh (noemap#15 original) so it can also run from
# scan.sh (noemap#289) at the end of a normal noemap discovery run, not
# only during installation.
#
# Requires: has_cmd, log (util.sh); blockdb_get/blockdb_list/blockdb_field
# (blockdb.sh); nssh on PATH; optionally is_local_ip (identity.sh) to skip
# self.
#
# ssh_key_bootstrap devices_db_path -- generates ~/.ssh/id_ed25519 if
# missing, distributes the public key to every reachable-without-password
# node in devices_db_path, prints manual ssh-copy-id instructions for
# nodes still needing first-time setup, then verifies the final handshake
# per alias.
ssh_key_bootstrap() {
    _skb_devdb="$1"

    export NOEMAP_SSH_ROLE=automation

    _skb_key="$HOME/.ssh/id_ed25519"
    _skb_pub="$_skb_key.pub"

    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$_skb_key" ]; then
        if has_cmd ssh-keygen; then
            ssh-keygen -t ed25519 -N "" -f "$_skb_key" -C "noemap@$(hostname 2>/dev/null || echo node)" >/dev/null 2>&1 \
                && log OK "generated ssh key: $_skb_key" \
                || { log WARN "ssh-keygen failed -- skipping key bootstrap"; return 0; }
        else
            log WARN "ssh-keygen not found -- skipping key bootstrap"; return 0
        fi
    else
        log INFO "ssh key already present: $_skb_key"
    fi
    chmod 600 "$_skb_key" 2>/dev/null || true
    [ -f "$_skb_pub" ] || { log WARN "no public key at $_skb_pub -- skipping distribution"; return 0; }

    [ -f "$_skb_devdb" ] && [ -s "$_skb_devdb" ] || { log INFO "no nodes registered -- key distribution skipped"; return 0; }
    has_cmd nssh || { log INFO "nssh unavailable -- key distribution skipped"; return 0; }

    _skb_pubdata="$(cat "$_skb_pub")"
    _skb_need_manual=""

    _skb_aliases="$(blockdb_list "$_skb_devdb" | awk '
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
    while IFS= read -r _skb_a; do
        [ -n "$_skb_a" ] || continue
        _skb_blk="$(blockdb_get "$_skb_devdb" alias "$_skb_a")"
        [ -n "$_skb_blk" ] || continue
        _skb_ip="$(blockdb_field "$_skb_blk" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_skb_ip"; then continue; fi
        if nssh "$_skb_a" "true" >/dev/null 2>&1; then
            nssh "$_skb_a" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$_skb_pubdata' ~/.ssh/authorized_keys || printf '%s\n' '$_skb_pubdata' >> ~/.ssh/authorized_keys" >/dev/null 2>&1 \
                && log OK "key ensured on $_skb_a" \
                || log WARN "key append to $_skb_a failed"
        else
            _skb_need_manual="$_skb_need_manual $_skb_a"
        fi
    done <<EOF_SKB1
$_skb_aliases
EOF_SKB1

    if [ -n "$_skb_need_manual" ]; then
        log WARN "nodes needing first-time key setup:$_skb_need_manual"
        for _skb_m in $_skb_need_manual; do
            printf '    run once:  ssh-copy-id -i %s %s\n' "$_skb_pub" "$_skb_m"
        done
    fi

    while IFS= read -r _skb_a2; do
        [ -n "$_skb_a2" ] || continue
        _skb_blk2="$(blockdb_get "$_skb_devdb" alias "$_skb_a2")"
        [ -n "$_skb_blk2" ] || continue
        _skb_ip2="$(blockdb_field "$_skb_blk2" ip)"
        if command -v is_local_ip >/dev/null 2>&1 && is_local_ip "$_skb_ip2"; then continue; fi
        if nssh "$_skb_a2" "true" >/dev/null 2>&1; then
            log OK "handshake $_skb_a2: OK"
        else
            log WARN "handshake $_skb_a2: needs setup"
        fi
    done <<EOF_SKB2
$_skb_aliases
EOF_SKB2
}
