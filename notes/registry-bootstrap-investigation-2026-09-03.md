# noemap — NOEMAP_SSH_ROLE override bug — Investigation & Fix Tracking

Session: 2026-09-03 (tx1, Termux)
Status: INVESTIGATION IN PROGRESS
Priority: P1
Task: noemap::03

## Previously resolved (noemap::01, done)

install.sh never cloned ~/.noemap-registry, causing node_alias()/
registry_row_by_hostkey() (identity.sh) to silently degrade to empty.
Fixed: install.sh now clones the registry (hard-fail) before the
symlink block, right after DATADIR is created. Verified via sandboxed
install (HOME/PREFIX override) in both states -- registry absent
(clones, exit 0) and registry present (skips, idempotent, exit 0).
Shipped to origin/main (commit 94b2d72). Not yet deployed to tx2.

## Problem Statement

Running install.sh (which calls ssh_key_bootstrap -> nssh internally)
produces an interactive password prompt against tx2, even though
ssh_key_bootstrap explicitly sets NOEMAP_SSH_ROLE=automation to force
BatchMode (fail-fast, never prompt) via ssh_config's Match block.

## Root Cause

bin/nssh line 72:
    export NOEMAP_SSH_ROLE=interactive

This is unconditional. When ssh_key_bootstrap (install.sh line 337)
exports NOEMAP_SSH_ROLE=automation and then calls nssh as a subprocess
(line 395/432: `nssh "$_ka" "true" </dev/null >/dev/null 2>&1`), the
exported value is inherited into nssh's process -- but nssh's own
line 72 immediately overwrites it with "interactive" before connecting,
discarding the caller's intent.

Consequence: by the time _ssh_connect() (nssh line 81-88) actually
invokes ssh, NOEMAP_SSH_ROLE is "interactive", not "automation". This
activates ssh_config's Match block for ControlMaster (line 26-27,
config/ssh_config) instead of the BatchMode block (line 38-39). Without
BatchMode yes, ssh falls back to its default behavior: prompt for a
password when no authorized key exists yet on the target.

Confirmed NOT the cause (ruled out):
- ssh_config's automation Match block (line 38-39) is correctly defined
  and would work if NOEMAP_SSH_ROLE reached ssh as "automation".
- ssh_key_bootstrap (both the install.sh-embedded copy, lines 334-440,
  and the extracted lib/ssh_bootstrap.sh) correctly exports
  NOEMAP_SSH_ROLE=automation and calls nssh with </dev/null redirection
  -- the export itself is correct on the caller side.
- The bug is isolated entirely to bin/nssh line 72.

## Fix Plan (NOT YET IMPLEMENTED)

1. bin/nssh line 72: only export NOEMAP_SSH_ROLE=interactive if the
   variable is not already set by the caller. E.g.:
     : "${NOEMAP_SSH_ROLE:=interactive}"
     export NOEMAP_SSH_ROLE
   This preserves current behavior for direct human invocation (no
   prior value set -> defaults to interactive) while letting
   ssh_key_bootstrap's automation value survive when nssh is called
   as an internal subroutine.
2. Verify no other caller of nssh relies on the unconditional overwrite
   (grep for NOEMAP_SSH_ROLE across the repo before changing).
3. Smoke test: reproduce the failing case (a devices.db entry for a
   host with no authorized key yet) and confirm nssh now fails fast
   (no password prompt) when invoked with NOEMAP_SSH_ROLE=automation
   pre-set, while direct `nssh <alias>` from an interactive shell still
   behaves as before (ControlMaster auto, prompts normally if needed).
4. Root-cause confirmation still needs one more live check: run `noemap`
   itself (not just install.sh) end-to-end against the now-cloned local
   registry, and confirm noemap's own local config/state matches what
   the registry (source of truth) says -- if any expected local file is
   missing, create it, then re-confirm noemap actually reads/uses it.

## Files Read So Far (this bug)
- bin/nssh (full)
- install.sh lines 304-461 (ssh_key_bootstrap embedded copy + config/ssh_config)
- lib/ssh_bootstrap.sh (full, ruled out)
- config/ssh_config (full)

## NEXT STEP
Implement bin/nssh fix (fix plan point 1), grep-verify no other caller
assumption breaks (point 2), smoke test both paths (point 3), then run
noemap live per point 4 before considering this closed.
