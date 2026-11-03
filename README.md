# beamline-scripts

Start, stop and health-check the **beamline lab fleet**: 13 KVM/libvirt VMs on
`beamlinehost` (Ubuntu 24.04), running an on-prem DevOps platform (GitLab,
Kubernetes + Argo CD, package repository, observability, CI), a SLURM/GPU
cluster and a Tango Controls lab (Tango, Sardana, HDB++).

The scripts run on the hypervisor, not inside Ansible: Ansible lives on
`admin.beamline`, which is itself a fleet member and is down whenever the fleet
is. Everything here is plain Bash, `virsh` and `ssh`.

Design rules the whole repository follows:

- **Honest exit codes.** A run exits 0 only if everything it was asked to do
  was verified good. "Could not check" is never reported as success.
- **Checks that can fail.** A check is enabled only after it has been shown
  to fail once against a wrong target.
- **Fail-closed hooks.** A hook that errors, times out or can't reach its
  host counts as a failure.
- **Data apart from logic.** `fleet.conf` holds hosts, tiers and timings;
  `fleet-lib.sh` holds the shared code; the scripts know no service by name.

---

## Contents

| Path | What it is |
|---|---|
| `fleet-up.sh` | Tiered start, SSH wait, per-host network checks, post-boot hooks |
| `fleet-down.sh` | Pre-shutdown hooks, then tiered ACPI shutdown (last tier first) |
| `fleet-check.sh` | Runs every executable `checks.d/*.sh` and summarises; read-only |
| `runbook-check.sh` | Compares files under `$HOME` with the RUNBOOK's embedded copies (sha256); read-only |
| `fleet.conf` | Fleet data only: groups, tiers, timings, SSH settings |
| `fleet-lib.sh` | Shared library, sourced by every script, check and hook; never executed |
| `checks.d/` | One health check per area ([contract](checks.d/README.md)) |
| `hooks/` | Optional per-host pre-shutdown / post-boot scripts ([contract](hooks/README.md)) |
| `logs/` | One log per `fleet-up.sh` / `fleet-down.sh` run, plus the lock file (gitignored) |

---

## The fleet

Groups mirror `lab-ansible/inventory/inventory.ini` on `admin.beamline`. Boot
order is by tier: `fleet-up.sh` starts tier 1 first, `fleet-down.sh` stops
tier 3 first and waits for each tier to reach `shut off` before the next.

| Tier | Hosts |
|---|---|
| 1 | `admin` (control), `gitlab`, `pkg` (packaging), `puppet` (configmgmt) |
| 2 | `k8cp` (k8s_control), `tango-db`, `obs` (observability), `hpc-ctl` (hpc_controller) |
| 3 | `k8w1`, `k8w2` (k8s_workers), `tango-ds`, `hpc-c1`, `hpc-gpu` (hpc_compute) |

All hosts are `<name>.beamline`. Parent groups: `kubernetes` = k8s_control +
k8s_workers, `tango` = tango_db + tango_ds, `hpc` = hpc_controller + hpc_compute.

---

## Requirements

On `beamlinehost`:

- Bash 4.3 or later (associative arrays, `[[ -v ]]`, `exec {fd}>`), coreutils
  `timeout`, util-linux `flock`.
- `virsh` with access to `qemu:///system` (override with `LIBVIRT_DEFAULT_URI`).
- OpenSSH, with the fleet key at `FLEET_SSH_KEY` (default `~/.ssh/beamline_vms`)
  and each VM's host key already in `known_hosts` (`FLEET_SSH_HOST_KEY_CHECKING=yes`).
- For `fleet-check.sh`: `curl` 7.75 or later, `jq`, `python3`, `chronyc`,
  `timedatectl`. The remote side of each check uses what that VM's role
  installs (`kubectl`, `scontrol`, `podman`, `ansible-playbook`, ...).

The VMs themselves are created by Terraform (`beamline-terraform`) and
configured by Ansible (`beamline-ansible`); this repository only starts,
stops and inspects them.

---

## Quick start

Run everything on `beamlinehost`, from the repository directory (it is not on
`PATH`):

```bash
cd ~/beamline-scripts
./fleet-up.sh --dry-run      # show the plan; starts no VM
./fleet-up.sh                # start all 13 VMs
./fleet-check.sh             # fast health checks
./fleet-down.sh              # graceful shutdown
```

Every script takes `--help`, which prints the timings currently set in
`fleet.conf`.

---

## Commands

### `fleet-up.sh`

```text
fleet-up.sh [--only=<list> | --skip=<list>] [--with-healthcheck] [--dry-run]
```

For each tier: `virsh start` every shut-off VM (`FLEET_START_STAGGER` s apart),
then wait up to `FLEET_SSH_WAIT_TIMEOUT` s per host for SSH. A host that does not
come up is reported and the next tier still starts. Then, on every ready host:
hostname, an IPv4 address on each of `FLEET_IFACES` (`lab0 nat0`), and one ping
to `FLEET_INTERNET_PROBE`. Finally the post-boot hooks run.

`--with-healthcheck` runs `fleet-check.sh` at the end. After a cold boot it is
usually better to wait a few minutes and run it by hand, since Kubernetes pods
and other services need time to settle.

### `fleet-down.sh`

```text
fleet-down.sh [--only=<list> | --skip=<list>] [--force] [--force-stop] [--dry-run]
```

Runs every pre-shutdown hook first. If one fails, nothing is shut down unless
`--force` is given. Then, last tier first, sends an ACPI shutdown to each VM
(`FLEET_SHUTDOWN_STAGGER` s apart) and waits up to `FLEET_SHUTDOWN_TIMEOUT` s
for the whole tier to be `shut off`.

If a tier times out, the run stops there and leaves the remaining tiers
running. `--force-stop` instead powers off (`virsh destroy`) the VMs still
running and continues.

### `fleet-check.sh`

```text
fleet-check.sh [--slow]
```

Runs every executable `checks.d/*.sh` in name order, each under
`FLEET_CHECK_TIMEOUT` s, and prints a summary. `--slow` also runs `*.slow.sh`
checks (Ansible drift) under `FLEET_SLOW_CHECK_TIMEOUT` s. It changes nothing
and takes no lock, so it can run alongside anything.

### `runbook-check.sh`

Compares the configuration files under `$HOME` on `beamlinehost`
(`beamlinehost-ansible`, `beamline-terraform`) with the sha256 manifest of
the copies embedded in the beamlinehost RUNBOOK (Sections 1-3). Prints
`MATCH`, `DIFFER` or `MISSING` per file. When the RUNBOOK changes, update
the manifest.

### Selecting hosts

`--only` and `--skip` take a comma-separated list of group names, parent
groups, full host names or bare names (`pkg` = `pkg.beamline`). An unknown name
is an error, never silently ignored. Examples:

```bash
./fleet-up.sh --only=kubernetes,control
./fleet-down.sh --skip=hpc --dry-run
```

### Exit codes

| Code | `fleet-up.sh` / `fleet-down.sh` / `fleet-check.sh` |
|---|---|
| 0 | Every selected host up / shut off cleanly; every check and hook passed |
| 1 | Anything else: a host not ready, a failed per-host check, a hook failure, a timeout, a forced stop, a check that failed or could not check |
| 2 | Usage or configuration error, raised before any lock, log or VM is touched |

`runbook-check.sh` exits 0 only if every file matches, else 1.

---

## Configuration: `fleet.conf`

Data only, sourced by `fleet-lib.sh`. When it is loaded the library checks that:

- every host is in exactly one tier, and every tier host is in a group;
- every timing is a whole number of seconds;
- `FLEET_SSH_HOST_KEY_CHECKING` is `yes` or `accept-new`;
- every `FLEET_DRIFT_SKIP_TAGS` entry is a plain tag name.

Before touching any VM, the scripts also check that every selected host
exists as a libvirt domain.

| Variable | Meaning |
|---|---|
| `FLEET_GROUPS`, `FLEET_CHILDREN` | Host groups, mirroring the Ansible inventory; kept in step by hand |
| `FLEET_TIERS` | Boot order, one tier per element |
| `FLEET_DOMAIN` | Suffix added to bare names (`beamline`) |
| `FLEET_START_STAGGER`, `FLEET_SHUTDOWN_STAGGER` | Pause between two `virsh start` / `virsh shutdown` calls |
| `FLEET_SSH_WAIT_TIMEOUT` | Per host: boot until SSH answers |
| `FLEET_SHUTDOWN_TIMEOUT` | Per tier: ACPI shutdown until `shut off` |
| `FLEET_HOOK_TIMEOUT` | Per hook, enforced with `timeout(1)` |
| `FLEET_POLL_INTERVAL` | Between two state or SSH probes |
| `FLEET_SSH_USER`, `FLEET_SSH_KEY`, `FLEET_SSH_CONNECT_TIMEOUT` | SSH from `beamlinehost` to the VMs |
| `FLEET_SSH_HOST_KEY_CHECKING` | `yes`; set `accept-new` only while rebuilding VMs, whose host keys legitimately change |
| `FLEET_IFACES`, `FLEET_INTERNET_PROBE` | Post-boot network checks |
| `FLEET_CHECK_TIMEOUT`, `FLEET_SLOW_CHECK_TIMEOUT` | Per check, normal and `*.slow.sh` |
| `FLEET_DRIFT_SKIP_TAGS` | `site.yml` play tags the drift check skips (roles not yet applied); empty = check every play |

No script compares `FLEET_GROUPS` with `inventory.ini`. When a VM is added,
update both, and put the new host in a tier.

---

## Health checks: `checks.d/`

| Check | What it verifies |
|---|---|
| `05-beamlinehost` | The hypervisor itself: chrony enabled and synchronised, clock offset, timezone, GNOME Remote Login off |
| `10-gitlab` | GitLab web UI and container registry (from here), readiness (on the VM), runner service |
| `20-kubernetes` | Kubernetes and Argo CD state, parsed from JSON (not table text) |
| `30-podman` | Rootless Podman on `pkg` |
| `40-pkg-repo` | Package site over verified TLS, apt signature and index integrity, conda indexes, HTTPS closed on `nat0` |
| `50-observability` | Prometheus (ready, rules, expected jobs and targets), Alertmanager Watchdog, per-host health timer, Grafana over TLS, exposure from here |
| `60-ci-runner` | GitLab Runner on `pkg`: service, held packages, one accepted registration, prune timer, publish path and sudoers rule |
| `70-slurm` | munge, MariaDB, slurmdbd, slurmctld; exactly the configured nodes, each usable with its GRES; accounting chain; ports dropped from here |
| `80-tango` | `tango-lab.target` and its units, Tango DB, each device ON and exported; CORBA ports reachable on `lab0`, closed on `nat0` |
| `82-sardana` | Pool, MacroServer and Door; Pool elements; MacroServer's view; `ActiveMntGrp`; ports |
| `85-hdbpp` | HDB++ EventSubscriber and ConfigurationManager; archived attribute count and storage; ports |
| `90-ansible-drift.slow` | `site.yml --check` from `admin.beamline` on every host: every recap line `changed=0 unreachable=0 failed=0` |

Each check reports `[OK]`, `[FAIL]` or `[CANNOT]` per finding and exits 0 OK,
1 FAIL, 2 could not check, or 3 skipped. A check without the executable bit is
disabled and listed as such. See [`checks.d/README.md`](checks.d/README.md) for
the contract and the rules a new check must follow.

---

## Hooks: `hooks/`

`hooks/<host>.pre-shutdown.sh` runs before any VM is shut down;
`hooks/<host>.post-boot.sh` runs after every targeted host answers over SSH.
Both run under `FLEET_HOOK_TIMEOUT` and are fail-closed. The current hooks are
for `hpc-ctl.beamline`:

- **pre-shutdown**: exits 1 while any SLURM job is anything other than
  pending, because the shutdown would kill it. It changes nothing.
- **post-boot**: waits up to 45 s for slurmctld to report exactly the
  configured nodes, all usable. It changes nothing.

Contract, environment and exit codes: [`hooks/README.md`](hooks/README.md).

---

## Logs and locking

- `fleet-up.sh` and `fleet-down.sh` copy their whole output to
  `logs/fleet-up-YYYYMMDD-HHMMSS.log` / `logs/fleet-down-...log`.
- The two share one `flock` lock, `logs/.fleet.lock`, so they cannot run at
  the same time. `fleet-check.sh` takes no lock.
- `logs/` is gitignored.

---

## When the fleet changes

- **New VM**: add it to `fleet.conf` groups *and* to a tier (the library
  refuses a host that is in no tier), and to the Ansible inventory.
- **Newly built service**: add a check in `checks.d/`, show it failing
  once against a wrong target, then make it executable.
- **Role applied by a rebuild**: remove its play tag from `FLEET_DRIFT_SKIP_TAGS`.
- **Host-specific start or stop behaviour**: add a hook that follows
  `hooks/README.md`.
- **Rebooting one SLURM compute node** isn't a job for these scripts. On
  `hpc-ctl`, use `scontrol reboot nextstate=resume`.

---

## Documentation

The design, the testing and the history of every change (with real outputs and
the mistakes found along the way) are written up in the lab handbook, Part 0,
*Fleet management scripts (`beamline-scripts`)*. `git log` follows the same
story: the old `morning.sh` / `evening.sh` / `healthcheck.sh`, then the rework
into a shared library with honest exit codes, then one check per handbook
chapter.
