# Fleet checks

`fleet-check.sh` runs every executable `checks.d/*.sh` in name order and
summarises them. Checks are read-only: they never change anything.

## Names

- `NN-area.sh` -- runs on every `fleet-check.sh` call, under
  `FLEET_CHECK_TIMEOUT` seconds.
- `NN-area.slow.sh` -- runs only with `fleet-check.sh --slow`, under
  `FLEET_SLOW_CHECK_TIMEOUT` seconds (e.g. Ansible drift, ~1-2 min).
- Not executable = disabled; listed as such in the summary. A chapter adds
  the checks for what it builds and enables them once that thing exists.

## Writing a check

`source "$FLEET_DIR/fleet-lib.sh"` (fleet-check.sh exports `FLEET_DIR`), then
report every finding with one of:

- `fleet_check_ok "..."` -- verified good.
- `fleet_check_fail "..."` -- verified bad.
- `fleet_check_cannot "..."` -- could not find out (ssh exit 255, no answer
  from a tool you depend on, unparseable output).

and end with `fleet_check_exit`: exit 1 if anything failed, else 2 if anything
could not be checked, else 0 (a check that reported nothing exits 2). Exit 3
means "skipped by the check itself".

Rules (the old fleet-check.sh broke each of these):

- Parse structured output (JSON) where a tool offers it, not table text:
  "NotReady" contains "Ready".
- Evaluate every line of a multi-host result, not "any line matches".
- `curl -f` treats a redirect as success; compare the status code you expect.
- A check must be able to fail: test it once against a wrong target.
- Use `fleet_ssh` (stdin is /dev/null) and tell 255 (unreachable) apart from
  a failed remote command.
