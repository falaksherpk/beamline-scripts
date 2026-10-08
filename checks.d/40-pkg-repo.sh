#!/usr/bin/env bash
# Internal package repository on pkg.beamline (handbook Ch15): the site over
# verified TLS, the apt repository's signature and index integrity, the conda
# channel's indexes, and that HTTPS stays closed on pkg's nat0 side.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=fleet-lib.sh
source "${FLEET_DIR:?run from fleet-check.sh}/fleet-lib.sh"

# Overridable only to test the check against a wrong target (checks.d/README.md).
HOST=${CHECK_PKG_HOST:-pkg.beamline}
# The apt signing key is trusted by its primary fingerprint, never just because
# pkg serves it: a key fetched from the server under test proves nothing alone.
APT_FPR=${CHECK_PKG_APT_FPR:-ECEE314121F9A4EA1CB1A2621AC8A9930C437FCF}
BASE="https://$HOST"
SUITE=noble
NAT_IFACE=nat0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# fetch URL FILE -> prints "code|curl-exit|curl-error"; body in FILE.
fetch() {
  curl -s -o "$2" --connect-timeout 5 --max-time 20 \
    -w '%{http_code}|%{exitcode}|%{errormsg}\n' "$1"
}

# 1. The site, over TLS verified against this host's trust store.
IFS='|' read -r code cexit cerr < <(fetch "$BASE/" "$tmp/index.html")
if [[ ${cexit:-x} != 0 ]]; then fleet_check_fail "site: $BASE/ -> no answer (curl exit ${cexit:-?}: ${cerr:-})"
elif [[ $code == 200 ]]; then fleet_check_ok "site: $BASE/ -> 200 over verified TLS"
else fleet_check_fail "site: $BASE/ -> HTTP $code (want 200)"; fi

# 2. apt: published key has the pinned fingerprint; InRelease verifies with it;
#    the Packages index matches the SHA256 that the signed InRelease lists.
apt_ok=1
IFS='|' read -r code cexit cerr < <(fetch "$BASE/beamline-apt-repo.asc" "$tmp/key.asc")
if [[ ${cexit:-x} != 0 || $code != 200 ]]; then
  fleet_check_fail "apt: public key $BASE/beamline-apt-repo.asc -> HTTP ${code:-?} (curl exit ${cexit:-?})"; apt_ok=0
else
  fprs=$(gpg --batch --quiet --with-colons --show-keys "$tmp/key.asc" 2>/dev/null | awk -F: '/^fpr:/{print $10}')
  if ! grep -qx "$APT_FPR" <<< "$fprs"; then
    fleet_check_fail "apt: published key does not carry the pinned fingerprint $APT_FPR"; apt_ok=0
  elif ! gpg --batch --quiet --dearmor < "$tmp/key.asc" > "$tmp/key.gpg" 2>/dev/null; then
    fleet_check_cannot "apt: could not convert the published key for gpgv"; apt_ok=0
  fi
fi
if (( apt_ok )); then
  IFS='|' read -r code cexit cerr < <(fetch "$BASE/apt/dists/$SUITE/InRelease" "$tmp/InRelease")
  if [[ ${cexit:-x} != 0 || $code != 200 ]]; then
    fleet_check_fail "apt: InRelease -> HTTP ${code:-?} (curl exit ${cexit:-?}: ${cerr:-})"
  elif gpgv --keyring "$tmp/key.gpg" --output "$tmp/Release" "$tmp/InRelease" >"$tmp/gpgv.log" 2>&1; then
    fleet_check_ok "apt: InRelease ($SUITE) signed by the key with fingerprint ${APT_FPR: -16}"
    want=$(awk '/^SHA256:/{s=1;next} /^[^ ]/{s=0} s && $3=="main/binary-amd64/Packages"{print $1}' "$tmp/Release")
    IFS='|' read -r code cexit cerr < <(fetch "$BASE/apt/dists/$SUITE/main/binary-amd64/Packages" "$tmp/Packages")
    if [[ ${cexit:-x} != 0 || $code != 200 ]]; then
      fleet_check_fail "apt: Packages index -> HTTP ${code:-?} (curl exit ${cexit:-?})"
    elif [[ -z $want ]]; then
      fleet_check_fail "apt: signed Release lists no SHA256 for main/binary-amd64/Packages"
    elif [[ $(sha256sum < "$tmp/Packages" | cut -d' ' -f1) != "$want" ]]; then
      fleet_check_fail "apt: Packages index does not match the SHA256 in the signed Release"
    else
      n=$(grep -c '^Package: ' "$tmp/Packages")
      fleet_check_ok "apt: Packages index matches the signed Release ($n package(s))"
    fi
  else
    fleet_check_fail "apt: InRelease signature does not verify: $(tail -1 "$tmp/gpgv.log")"
  fi
fi

# 3. conda: noarch and linux-64 indexes parse; noarch lists at least one package.
for subdir in noarch linux-64; do
  IFS='|' read -r code cexit cerr < <(fetch "$BASE/conda/$subdir/repodata.json" "$tmp/repodata.json")
  if [[ ${cexit:-x} != 0 || $code != 200 ]]; then
    fleet_check_fail "conda: $subdir/repodata.json -> HTTP ${code:-?} (curl exit ${cexit:-?}: ${cerr:-})"; continue
  fi
  verdict=$(python3 - "$subdir" "$tmp/repodata.json" <<'PY' 2>&1
import json, sys
subdir, path = sys.argv[1], sys.argv[2]
r = json.load(open(path))
n = len(r.get("packages", {})) + len(r.get("packages.conda", {}))
if r.get("info", {}).get("subdir") != subdir:
    print(f"bad: info.subdir is {r.get('info', {}).get('subdir')!r}")
elif subdir == "noarch" and n == 0:
    print("bad: no packages")
else:
    print(f"ok: {n} package(s)")
PY
  ) || verdict="bad: unparseable"
  if [[ $verdict == ok:* ]]; then fleet_check_ok "conda: $subdir/repodata.json valid, ${verdict#ok: }"
  else fleet_check_fail "conda: $subdir/repodata.json ${verdict#bad: }"; fi
done

# 4. HTTPS must not answer on pkg's nat0 address (ufw allows 443 from the lab
#    network only). A timeout means dropped; anything else means it got through.
rc=0
nat_ip=$(fleet_ssh "$HOST" "ip -4 -o addr show dev $NAT_IFACE" 2>&1) || rc=$?
if (( rc == 255 )); then
  fleet_check_cannot "nat0 side: ssh to $HOST failed: $nat_ip"
elif (( rc != 0 )); then
  fleet_check_cannot "nat0 side: could not read $NAT_IFACE address on $HOST: $nat_ip"
else
  nat_ip=$(awk '{split($4, a, "/"); print a[1]; exit}' <<< "$nat_ip")
  IFS='|' read -r code cexit cerr < <(curl -s -o /dev/null --connect-timeout 3 --max-time 5 \
    --resolve "$HOST:443:$nat_ip" -w '%{http_code}|%{exitcode}|%{errormsg}\n' "$BASE/")
  if [[ $cexit == 28 ]]; then fleet_check_ok "nat0 side: $HOST:443 via $nat_ip times out (filtered)"
  else fleet_check_fail "nat0 side: $HOST:443 via $nat_ip answered (curl exit $cexit, HTTP $code); want a timeout"; fi
fi

fleet_check_exit
