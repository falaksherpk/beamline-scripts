# Fleet hooks

Optional per-host scripts run by `fleet-up.sh` and `fleet-down.sh`. The fleet
scripts have no knowledge of any particular service; anything host-specific
(draining a scheduler, resuming nodes, flushing a queue) belongs in a hook.

## Names

- `hooks/<host>.pre-shutdown.sh` -- run by `fleet-down.sh` for each host in
  scope, before any VM is shut down.
- `hooks/<host>.post-boot.sh` -- run by `fleet-up.sh` for each host in scope,
  after every targeted host answers over SSH.

`<host>` is the full name as in `fleet.conf` (e.g. `hpc-ctl.beamline`). Only
executable files are run. `--dry-run` lists the hooks it would run and runs none.

## Environment

- `FLEET_HOST` -- the host this hook is for.
- `FLEET_DIR` -- the beamline-scripts directory. `source "$FLEET_DIR/fleet-lib.sh"`
  provides `fleet_ssh <host> <command...>`, which uses the SSH settings from
  `fleet.conf` and returns ssh's status unchanged: 255 means ssh itself failed
  (host unreachable, key rejected); anything else is the remote command's status.
  Its stdin is `/dev/null` (`ssh -n`), so it is safe inside a `while read`
  loop. To feed the remote command on stdin, use `fleet_ssh_script` instead
  (e.g. `fleet_ssh_script <host> bash -s <<< "$script"`).
- `FLEET_FORCE` -- `true` or `false` (pre-shutdown only: was `--force` given).

## Exit codes

- `0` -- done / safe to proceed.
- `1` -- checked, and found unsafe (pre-shutdown) or failed (post-boot).
- anything else -- could not check (host unreachable, command missing,
  timed out: `timeout` exits 124).

Fail-closed: every non-zero exit is a failure.

- pre-shutdown: aborts the whole run before any VM is touched, unless `--force`
  is given; with `--force` the run continues, and the failure still appears in
  the summary and the exit code.
- post-boot: the boot sequence continues; the failure appears in the summary
  and the run exits 1.

Each hook runs under `timeout` with `HOOK_TIMEOUT` seconds from `fleet.conf`.

## Rules for writing a hook

- Print "safe" or "OK" only after a command that actually succeeded. No
  `|| true` or `2>/dev/null` on the check itself: empty output from a failed
  command is not the same as "nothing running".
- Tell "unreachable" (ssh exit 255) apart from "command failed".
- Every wait loop prints its outcome, including a timeout.
- Idempotent: safe to run twice.
- No secrets in arguments or output.

## History

The `hpc-ctl.beamline` SLURM hooks (job check and drain before shutdown, node
resume after boot) were removed because SLURM is not installed on the rebuilt
fleet. To find them: `git log --oneline --diff-filter=D -- hooks/`.
