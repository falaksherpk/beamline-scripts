#!/usr/bin/env bash
# runbook-check.sh -- compare real files under $HOME to the heredoc blocks in RUNBOOK v1.10 (Sections 1-3)
# Read-only: changes nothing. MATCH = byte-identical to the RUNBOOK block.
# Exit status: 0 only if every file matches; 1 if any differs or is missing.
set -u
match=0; differ=0; missing=0
while read -r sum bytes dir rel; do
  path="$HOME/$dir/$rel"
  if [ ! -f "$path" ]; then
    printf 'MISSING  %s/%s\n' "$dir" "$rel"; missing=$((missing+1)); continue
  fi
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  size=$(wc -c < "$path")
  if [ "$actual" = "$sum" ]; then
    printf 'MATCH    %s/%s\n' "$dir" "$rel"; match=$((match+1))
  else
    printf 'DIFFER   %s/%s (RUNBOOK %s bytes, real %s bytes)\n' "$dir" "$rel" "$bytes" "$size"; differ=$((differ+1))
  fi
done << 'MANIFEST'
6052c9dfa84a19c162b0cbafb1bfdfdd6446a091d0fa1032d774f22532583858 306 beamlinehost-ansible ansible.cfg
e509b1f867ba48750a23d6c3aef86b0a546a370c7336727ffcbc3b261652ba10 51 beamlinehost-ansible inventory/inventory.ini
86b261d349fb682a821a1f9dc632a5cc90315ec1bdd251654d334dd22b2f361e 59 beamlinehost-ansible roles/common/defaults/main.yml
5a27686bbdedd1ece98925e0b8cf9c3aa7d88da5f1cb18d0b3d7946d87f4f297 2296 beamlinehost-ansible roles/common/tasks/main.yml
56e87d3a7ced92679f200c38e634f3e46b51f23535a3957dc520538ff9ffa06f 509 beamlinehost-ansible roles/common/templates/hosts.j2
84c83d109f74bfc5f49c087be8c93d755cc4538a781ef7c2a6598b796cb14219 119 beamlinehost-ansible roles/common/handlers/main.yml
51eae34d92788ba09de0a5b047910b3d414538334504bc69d3bdfff71a7bf556 1944 beamlinehost-ansible roles/common/files/beamline-ca.crt
6c63ea2ec3ea39290d621bd476a478332de249d5d376372372226eb7a20ff32f 427 beamlinehost-ansible roles/hypervisor/defaults/main.yml
cfdde1dbf38744c37251b1b7b354d590b337b9149a0cbc69949caae0b83eb8ee 6066 beamlinehost-ansible roles/hypervisor/tasks/main.yml
01104c9a71584744c4008a52f65fea6218c9b3a4d86de011e04148148d01af03 113 beamlinehost-ansible roles/hypervisor/templates/default-pool.xml.j2
aa6c86f7259a6d13e0a60900b3641b14181421c1b6b9cdeb3e428cb500902ab1 239 beamlinehost-ansible roles/hypervisor/templates/default-network.xml.j2
6fd5deb3808685816df72ab8c37144fcbd000668684f0037f7a19f8271d1c781 232 beamlinehost-ansible roles/hypervisor/templates/beamlinenet.xml.j2
4b6eb8333c0fb9e3d02ad178a77d4aa066a1ce8508fec3aebaed342ffb8c438d 544 beamlinehost-ansible roles/hypervisor/templates/vfio-pci.conf.j2
a1ce059244a42384ad66b43e38c44e1232198a9744f18135e5e86551229c106a 983 beamlinehost-ansible roles/terraform/tasks/main.yml
806a7c03af41e1b5bb42eb79d2d73f52d3003f7a3299c2aaa6e4b78048ac9fd6 1552 beamlinehost-ansible roles/operator_gui/defaults/main.yml
2625b432513475e098fa79db8a790905dcef4f820d5656744b6c9ceccc24b3a6 4846 beamlinehost-ansible roles/operator_gui/tasks/main.yml
e8b59f8f4cd2bc150b5fb60d57f747448ad59bed70479ad1655bdbadcd1d9f42 1889 beamlinehost-ansible roles/operator_gui/tasks/desktop.yml
1b87775f49bf7be6abea9270d8b59e5a4559d2b027f2aa234c17382dbe4695fe 4172 beamlinehost-ansible roles/operator_gui/files/requirements.txt
451a3a7686c7d57227c0d761c3b3ec74d1399ed72f83c2a44ed3c0d0e970c863 3807 beamlinehost-ansible roles/operator_gui/files/beamline-unlock-keyring
72620fe3422e1c467617d55ccc07bb35851d64f02468c586d122b632b83f4aba 519 beamlinehost-ansible roles/operator_gui/templates/beamline-gui-env.j2
1be9f2c6fa7098b89b51fbb5e402808f668a87148f2f2dc22ca1ddedbb075e40 654 beamlinehost-ansible roles/operator_gui/templates/beamline-gui.j2
758d830399c1b2c395e3cc7cc1a67e851061c5c5cd5764abfeff9b1145e33098 151 beamlinehost-ansible site.yml
795e7196e21423632c5fbd9b8e6c2d1172550a7b9d79d236d74435108a082901 20 beamlinehost-ansible .gitignore
4114fbbcb9b4f65c00302aede732c1b54411c7fee8e32924af9d33f127e9b91b 175 beamline-terraform providers.tf
0f79f5bd9bed86bc7cd240f8f5f86a71a76d494818b85a5601f870d3527d0dc3 3468 beamline-terraform variables.tf
9f435c65392a4af2b3601651254e5acb883a890e67f8221e9bcd13f65af40f44 4646 beamline-terraform main.tf
6e4917d6239d8a514921b41fd2f22596c13bfca462e7819b6a3601ec80a5236c 476 beamline-terraform cloud-init/user-data.tmpl
feecce4f21416d76b7ee2d9d4317aadc135938fbf45b09b60781efe187710991 202 beamline-terraform cloud-init/network-config.tmpl
5e18b51ca44e024769f7992b1ae501d5c2bb7c050a85700ed9f9fd688f3eaebf 40 beamline-terraform .gitignore
42a1dd6219d57b38997f62f2c00e885a9c34ea74aafe2ad08369d942b337071d 338 beamline-terraform tf.sh
MANIFEST
echo
echo "match=$match differ=$differ missing=$missing (of $((match+differ+missing)))"
[ "$differ" -eq 0 ] && [ "$missing" -eq 0 ]
