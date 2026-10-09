#!/usr/bin/env bash
# CI runner on pkg.beamline (handbook Ch17): gitlab-runner running and its
# packages held, exactly one registered runner and GitLab accepting it, the
# weekly image prune scheduled and not failing, and the publishing path of CI
# jobs: linger for both users, the drop directory (owner, mode, nothing left
# behind) and a sudoers rule that allows exactly the two beamline-publish commands.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_CI_HOST:-pkg.beamline}
# What beamline-ansible's pkg role configures (Ch17); keep the two in step.
DROP=/var/spool/beamline-publish
DROP_STAT="gitlab-runner:falak 2750"
SUDOERS=/etc/sudoers.d/gitlab-runner-publish
SUDO_RULE='(falak) NOPASSWD: /usr/local/bin/beamline-publish deb /var/spool/beamline-publish/*.deb, /usr/local/bin/beamline-publish conda /var/spool/beamline-publish/*.conda'
# A hand-over file older than this was left behind by a job (jobs remove theirs).
STALE_MIN=60

# Runs on the host as FLEET_SSH_USER, with sudo -n for what needs root. The
# values above go first, quoted by printf %q; the whole program travels
# base64-encoded, so its quoting does not depend on two shells.
remote=$( {
  printf 'drop=%q drop_stat=%q sudoers=%q rule=%q stale=%q\n' \
    "$DROP" "$DROP_STAT" "$SUDOERS" "$SUDO_RULE" "$STALE_MIN"
  cat << 'SH'
say() { printf '%s|%s\n' "$1" "$2"; }
nocolor() { sed 's/\x1b\[[0-9;]*m//g'; }
root=1
if ! sudo -n true 2> /dev/null; then
  root=0
  say CANNOT "sudo -n as $(id -un) needs a password: registration, sudoers file and rule not checked"
fi

# 1. The service.
a=$(systemctl is-active gitlab-runner 2>&1)
e=$(systemctl is-enabled gitlab-runner 2>&1)
if [[ $a == active && $e == enabled ]]; then say OK "gitlab-runner service: active, enabled"
else say FAIL "gitlab-runner service: ${a//$'\n'/ }, ${e//$'\n'/ } (want active, enabled)"; fi

# 2. Both packages installed and held, at one version (the runner needs its helper images).
versions=()
for p in gitlab-runner gitlab-runner-helper-images; do
  s=$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$p" 2> /dev/null) || s=""
  st=${s%%|*} v=${s#*|}
  if [[ -z $s ]]; then say FAIL "$p: not installed"; continue; fi
  versions+=("$v")
  if [[ ${st:0:2} == hi ]]; then say OK "$p $v: installed, held"
  else say FAIL "$p $v: dpkg status '${st% }' (want hi: held, installed)"; fi
done
if (( ${#versions[@]} == 2 )) && [[ ${versions[0]} != "${versions[1]}" ]]; then
  say FAIL "runner packages at different versions: ${versions[*]}"
fi

# 3. Exactly one registered runner, and GitLab accepts it. verify only asks
#    GitLab; never add --delete here, which would remove a runner it rejects.
if (( root )); then
  n=$(sudo -n grep -c '^\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>&1)
  out=$(sudo -n gitlab-runner verify 2>&1)
  vrc=$?
  out=$(nocolor <<< "$out")
  valid=$(grep -c 'is valid' <<< "$out")
  if [[ $n == 1 && $vrc == 0 && $valid == 1 ]]; then
    say OK "runner: 1 registered, GitLab accepts it ($(grep -o 'runner=[^ ]*' <<< "$out" | head -1))"
  else
    say FAIL "runner: ${n//$'\n'/ } in config.toml, verify exit $vrc, $valid valid; $(grep -iE 'valid|error|fatal' <<< "$out" | tail -1 | tr -s ' ' | cut -c1-160)"
  fi
fi

# 4. The weekly prune: timer enabled, active and scheduled; its last run did not fail.
t=gitlab-runner-podman-prune
te=$(systemctl is-enabled "$t.timer" 2>&1)
ta=$(systemctl is-active "$t.timer" 2>&1)
next=$(systemctl show -p NextElapseUSecRealtime --value "$t.timer" 2>&1)
res=$(systemctl show -p Result --value "$t.service" 2>&1)
if [[ $te == enabled && $ta == active && -n $next && $res == success ]]; then
  say OK "image prune: timer enabled, next run $next; last run: $res"
else
  say FAIL "image prune: timer ${te//$'\n'/ }/${ta//$'\n'/ }, next '${next//$'\n'/ }', service result '${res//$'\n'/ }' (want enabled/active, a next run, success)"
fi

# 5. Linger for the runner user (jobs) and the repository owner (beamline-publish).
for u in gitlab-runner falak; do
  l=$(loginctl show-user "$u" -p Linger --value 2>&1)
  if [[ $l == yes ]]; then say OK "linger: $u"
  else say FAIL "linger: $u -> '${l//$'\n'/ }' (want yes)"; fi
done

# 6. The drop directory: owner, group, setgid mode; no file left behind.
s=$(stat -c '%U:%G %a' "$drop" 2>&1)
if [[ $s == "$drop_stat" ]]; then say OK "drop directory $drop: $s"
else say FAIL "drop directory $drop: ${s//$'\n'/ } (want $drop_stat)"; fi
if old=$(find "$drop" -mindepth 1 -mmin +"$stale" 2>&1); then
  k=$(grep -c . <<< "$old")
  if (( k == 0 )); then say OK "drop directory: nothing older than $stale min"
  else say FAIL "drop directory: $k entr(y/ies) older than $stale min, left behind by a job: $(head -1 <<< "$old")"; fi
elif [[ -d $drop ]]; then
  say CANNOT "drop directory: could not list it: ${old//$'\n'/ }"
fi

# 7. The sudoers file (owner, mode, syntax) and gitlab-runner's complete rights.
if (( root )); then
  s=$(sudo -n stat -c '%U:%G %a' "$sudoers" 2>&1)
  if [[ $s == "root:root 440" ]]; then say OK "sudoers file $sudoers: $s"
  else say FAIL "sudoers file $sudoers: ${s//$'\n'/ } (want root:root 440)"; fi
  if v=$(sudo -n visudo -c 2>&1); then say OK "sudoers: visudo -c parses every file"
  else say FAIL "sudoers: visudo -c: $(grep -v 'parsed OK' <<< "$v" | head -1)"; fi
  listing=$(sudo -n -l -U gitlab-runner 2>&1)
  rights=$(awk 'f && NF {sub(/^ +/, ""); print} /may run the following commands/ {f = 1}' <<< "$listing")
  if [[ $rights == "$rule" ]]; then
    say OK "sudoers: gitlab-runner may run exactly the two beamline-publish commands, as falak"
  elif [[ -z $rights ]]; then
    say FAIL "sudoers: gitlab-runner may run nothing: $(head -1 <<< "$listing" | cut -c1-160)"
  else
    say FAIL "sudoers: gitlab-runner's rights are not exactly the publish rule: '$(tr '\n' ';' <<< "$rights" | cut -c1-200)'"
  fi
fi
say END "reached"
SH
} | base64 -w0 )

rc=0
out=$(fleet_ssh "$HOST" "echo $remote | base64 -d | bash" 2>&1) || rc=$?
if (( rc == 255 )); then
  fleet_check_cannot "ssh to $HOST failed: ${out:0:300}"
else
  n=0 end=0
  while IFS='|' read -r kind msg; do
    case $kind in
      OK) fleet_check_ok "$msg"; n=$(( n + 1 )) ;;
      FAIL) fleet_check_fail "$msg"; n=$(( n + 1 )) ;;
      CANNOT) fleet_check_cannot "$msg"; n=$(( n + 1 )) ;;
      END) end=1 ;;
    esac
  done <<< "$out"
  if (( rc != 0 || end == 0 )); then
    fleet_check_cannot "checks on $HOST did not reach their end (exit $rc, $n verdict(s)); last output: $(tail -n 2 <<< "$out" | tr '\n' ' ')"
  fi
fi

fleet_check_exit
