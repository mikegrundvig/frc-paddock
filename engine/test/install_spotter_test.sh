# shellcheck shell=bash
# install-spotter.sh, offline, on a directory tree: Spotter's agent from its .deb, packs with their
# polkit rules, and the root job for the drive's health.

setup_install() {
  need systemctl dpkg-deb
  mkdir -p "$TMP/root/etc/systemd/system"
  make_agent_deb
  make_photonvision_pack
}

run_install() {
  "$ENGINE/install-spotter.sh" --root "$TMP/root" --offline --deb "$TMP/frc-spotter.deb" \
    --pack "$TMP/photonvision-pack" "$@"
}

test_install_puts_the_agent_and_packs_in_place() {
  setup_install
  run_install
  local root=$TMP/root
  assert_file "$root/usr/lib/frc-spotter/frc-spotter.jar"
  assert_mode "$root/usr/lib/frc-spotter/bin/frc-spotter" 755
  cmp -s "$root/usr/lib/systemd/system/frc-spotter.service" "$TMP/agent-unit" ||
    fail "the agent's unit wasn't installed"
  assert_file "$root/usr/lib/sysusers.d/frc-spotter.conf"
  local wants=$root/etc/systemd/system/multi-user.target.wants
  [[ -L $wants/frc-spotter.service ]] || fail "the agent isn't enabled"
  # PhotonVision's pack, where the agent reads its packs, with its polkit rule.
  local pack=$root/usr/lib/frc-spotter/packs/photonvision
  assert_file "$pack/pack.json"
  assert_mode "$pack/bin/photonvision-helper" 755
  assert_file "$pack/lib/photonvision-helper.jar"
  assert_file "$root/usr/share/polkit-1/rules.d/61-frc-spotter-photonvision.rules"
  [[ -L $wants/coprocessor-facts.service ]] || fail "the facts helper isn't enabled"
  [[ -L $root/etc/systemd/system/timers.target.wants/coprocessor-facts.timer ]] ||
    fail "the facts timer isn't enabled"
  assert_mode "$root/usr/local/lib/coprocessor/coprocessor-facts.sh" 755
}

test_install_refuses_an_agent_that_would_run_as_root() {
  setup_install
  sed -i '/^User=/d; /^Group=/d' "$TMP/agent-unit"
  make_agent_deb
  assert_fails "would run the agent as root" run_install
  printf '[Service]\nUser=root\n' >>"$TMP/agent-unit"
  make_agent_deb
  assert_fails "would run the agent as root" run_install
}

test_install_refuses_an_agent_account_its_polkit_rules_dont_name() {
  setup_install
  sed -i 's/^User=frc-spotter$/User=someone-else/' "$TMP/agent-unit"
  make_agent_deb
  assert_fails "but its polkit rules are for 'frc-spotter'" run_install
}

# The rules, the agent package's and PhotonVision's pack's, run in order as polkit runs them,
# against the requests they must allow and refuse.
test_soft_off_rules_allow_powering_off_and_stopping_photonvision_only() {
  setup_install
  need node
  run_install
  cat >"$TMP/rule-test.js" <<'EOF'
const fs = require("fs");
const vm = require("vm");
const rules = [];
const polkit = {
  Result: { YES: "yes", NO: "no", NOT_HANDLED: null },
  addRule: (f) => { rules.push(f); },
};
// polkit runs every rules file in the order of its name.
const name = (path) => path.split("/").pop();
for (const file of process.argv.slice(2).sort((a, b) => name(a).localeCompare(name(b)))) {
  vm.runInNewContext(fs.readFileSync(file, "utf8"), { polkit });
}
const ask = (user, id, details) => {
  for (const rule of rules) {
    const result = rule({ id, lookup: (k) => (details || {})[k] }, { user });
    if (result !== null && result !== undefined) return String(result);
  }
  return "null";
};
const agent = "frc-spotter";
const cases = [
  [agent, "org.freedesktop.login1.power-off", {}, "yes"],
  [agent, "org.freedesktop.login1.power-off-multiple-sessions", {}, "yes"],
  [agent, "org.freedesktop.systemd1.manage-units", { unit: "photonvision.service", verb: "stop" }, "yes"],
  [agent, "org.freedesktop.systemd1.manage-units", { unit: "photonvision.service", verb: "restart" }, "yes"],
  [agent, "org.freedesktop.systemd1.manage-units", { unit: "photonvision.service", verb: "start" }, "no"],
  [agent, "org.freedesktop.systemd1.manage-units", { unit: "ssh.service", verb: "stop" }, "no"],
  [agent, "org.freedesktop.systemd1.manage-unit-files", {}, "no"],
  [agent, "org.freedesktop.login1.reboot", {}, "no"],
  [agent, "org.freedesktop.login1.power-off-ignore-inhibit", {}, "no"],
  ["photon", "org.freedesktop.login1.power-off", {}, "null"],
  ["root", "org.freedesktop.systemd1.manage-units", { unit: "photonvision.service", verb: "stop" }, "null"],
];
let failed = 0;
for (const [user, id, details, expected] of cases) {
  const got = ask(user, id, details);
  if (got !== expected) {
    console.log(`${user} ${id} ${JSON.stringify(details)}: expected ${expected}, got ${got}`);
    failed++;
  }
}
process.exit(failed ? 1 : 0);
EOF
  node "$TMP/rule-test.js" "$TMP"/root/usr/share/polkit-1/rules.d/*.rules ||
    fail "the soft-off rules decide wrongly"
}

test_install_needs_the_agents_package_and_real_packs() {
  setup_install
  assert_fails "no agent package at" run_install --deb "$TMP/nothing.deb"
  assert_fails "no pack at" run_install --pack "$TMP/nothing"
}

test_install_can_be_rerun() {
  setup_install
  run_install
  local first
  first=$(tree_digest "$TMP/root")
  run_install
  assert_eq "$(tree_digest "$TMP/root")" "$first" "the tree after a second run"
}

test_install_puts_a_team_pack_without_an_install_script_in_place() {
  setup_install
  mkdir -p "$TMP/lidar/bin"
  printf '{\n  "journalUnits": [],\n  "pack": "lidar",\n  "probes": []\n}\n' >"$TMP/lidar/pack.json"
  echo 'pack: lidar' >"$TMP/lidar/pack.yaml"
  printf '#!/bin/sh\necho ok\n' >"$TMP/lidar/bin/lidar-check"
  chmod 755 "$TMP/lidar/bin/lidar-check"
  echo '// the lidar pack' >"$TMP/lidar/62-frc-spotter-lidar.rules"
  run_install --pack "$TMP/lidar"
  local pack=$TMP/root/usr/lib/frc-spotter/packs/lidar
  assert_file "$pack/pack.json"
  assert_mode "$pack/bin/lidar-check" 755
  assert_no_file "$pack/pack.yaml"
  assert_no_file "$pack/62-frc-spotter-lidar.rules"
  assert_file "$TMP/root/usr/share/polkit-1/rules.d/62-frc-spotter-lidar.rules"
}
