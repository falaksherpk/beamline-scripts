#!/usr/bin/env bash
# Ansible drift: site.yml --check from admin.beamline on every host, skipping
# the plays tagged in FLEET_DRIFT_SKIP_TAGS (roles defined but not yet applied
# by the rebuild). Skipping plays, not hosts, keeps those hosts in common and
# node_exporter: excluding whole groups once hid real drift there (Ch16).
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"
HOST=admin.beamline
# shellcheck disable=SC2088  # the remote shell expands ~, not this one
REPO="~/lab-ansible"

read -ra skip <<< "${FLEET_DRIFT_SKIP_TAGS:-}"
skip_csv=$(IFS=,; echo "${skip[*]}")

# LC_ALL: ansible refuses to start over a non-interactive ssh without it.
run="cd $REPO && LC_ALL=C.UTF-8 ansible-playbook site.yml"
if [[ -n $skip_csv ]]; then run+=" --skip-tags '$skip_csv'"; fi

# Every skipped tag must be the tag of a whole play in site.yml: a typo would
# otherwise skip nothing, and a task-level tag would hide part of a play.
if (( ${#skip[@]} )); then
  rc=0
  tag_listing=$(fleet_ssh "$HOST" "cd $REPO && LC_ALL=C.UTF-8 ansible-playbook site.yml --list-tags" 2>&1) || rc=$?
  if (( rc != 0 )); then
    fleet_check_cannot "ansible-playbook --list-tags on $HOST exited $rc: ${tag_listing:0:300}"; fleet_check_exit
  fi
  for t in "${skip[@]}"; do
    play=$(sed -nE "s/^  play #[0-9]+ \(([^)]*)\): (.*[^[:space:]])[[:space:]]+TAGS: \[$t\]\$/\1|\2/p" <<< "$tag_listing")
    if [[ -z $play ]]; then
      fleet_check_cannot "FLEET_DRIFT_SKIP_TAGS: '$t' is not the tag of a play in site.yml"; fleet_check_exit
    fi
    printf '  [NOTE]   not checked: play "%s" (hosts: %s) -- tag %s in FLEET_DRIFT_SKIP_TAGS, fleet.conf\n' "${play#*|}" "${play%%|*}" "$t"
  done
fi

# The plays site.yml contains (read without connecting to any host).
rc=0
listing=$(fleet_ssh "$HOST" "$run --list-hosts" 2>&1) || rc=$?
if (( rc != 0 )); then
  fleet_check_cannot "ansible-playbook --list-hosts on $HOST exited $rc: ${listing:0:300}"; fleet_check_exit
fi
mapfile -t expected < <(sed -nE 's/^  play #[0-9]+ \([^)]*\): (.*)\tTAGS: .*$/\1/p' <<< "$listing")
if (( ${#expected[@]} == 0 )); then
  fleet_check_cannot "found no plays in the --list-hosts output of site.yml"; fleet_check_exit
fi

rc=0
out=$(fleet_ssh "$HOST" "$run --check" 2>&1) || rc=$?
if (( rc == 255 )); then
  fleet_check_cannot "ssh to $HOST failed: ${out:0:300}"; fleet_check_exit
fi

# Ansible ends the whole run once every host of a play has failed, and later
# plays never start. Their hosts still get clean-looking recap lines, so
# check that every play was reached before trusting the recap.
mapfile -t reached < <(sed -nE 's/^PLAY \[(.*)\] \**$/\1/p' <<< "$out")
missing=0
for play in "${expected[@]}"; do
  found=false
  for r in "${reached[@]}"; do if [[ $r == "$play" ]]; then found=true; break; fi; done
  if [[ $found != true ]]; then
    fleet_check_cannot "play not reached (the run stopped earlier): $play"; missing=$(( missing + 1 ))
  fi
done
if (( missing == 0 )); then fleet_check_ok "all ${#expected[@]} plays of site.yml reached"; fi

recap=$(sed -n '/^PLAY RECAP/,$p' <<< "$out" | grep -E '^[^ ]+ +: ok=')
if [[ -z $recap ]]; then
  fleet_check_cannot "ansible-playbook exited $rc without a PLAY RECAP; last lines: $(tail -n 3 <<< "$out" | tr '\n' ' ')"
  fleet_check_exit
fi

# Every recap line, not "any line": changed=0, unreachable=0, failed=0.
while read -r host _ fields; do
  declare -A f=()
  for kv in $fields; do f[${kv%%=*}]=${kv#*=}; done
  if (( ${f[changed]:-1} == 0 && ${f[unreachable]:-1} == 0 && ${f[failed]:-1} == 0 )); then
    fleet_check_ok "$host: no drift (ok=${f[ok]:-?})"
  else
    fleet_check_fail "$host: changed=${f[changed]:-?} unreachable=${f[unreachable]:-?} failed=${f[failed]:-?}"
  fi
  unset f
done <<< "$recap"

# Name the tasks behind any change or failure.
# Handlers count in the recap too: name them as handlers, not under the last task.
tasks=$(awk '/^(TASK|RUNNING HANDLER) \[/ {t=$0; hd=($0 ~ /^RUNNING HANDLER/); sub(/^(TASK|RUNNING HANDLER) \[/,"",t); sub(/\] \**$/,"",t); if (hd) t="handler " t}
             /^(changed|failed|fatal):/ {split($2,h,"]"); gsub(/\[/,"",h[1]); print "    " $1 " " t " -> " h[1]}' <<< "$out" | sort -u)
if [[ -n $tasks ]]; then printf '  tasks behind the findings:\n%s\n' "$tasks"; fi

fleet_check_exit
