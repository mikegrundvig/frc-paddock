# shellcheck shell=bash
# The engine's stamp.sh: what it writes for a computer, and what it refuses.

setup_stamp() {
  need_yq
  make_team
  make_settings_tool
}

test_team_numbers_split_into_te_and_am() {
  # shellcheck source=../lib/common.sh
  . "$ENGINE/lib/common.sh"
  assert_eq "$(team_prefix 1)" 10.0.1
  assert_eq "$(team_prefix 254)" 10.2.54
  assert_eq "$(team_prefix 1002)" 10.10.2
  assert_eq "$(team_prefix 12345)" 10.123.45
  assert_eq "$(team_prefix 25599)" 10.255.99
}

test_stamp_writes_the_computers_identity() {
  setup_stamp
  run_stamp vision-front
  local root=$TMP/out/root
  assert_eq "$(cat "$root/etc/hostname")" vision-front hostname
  # Every computer in the table, by its robot address.
  assert_contains "$root/etc/hosts" $'10.12.34.11\tvision-front'
  assert_contains "$root/etc/hosts" $'10.12.34.12\tvision-back'
  assert_contains "$root/etc/hosts" $'127.0.0.1\tlocalhost'
  assert_not_contains "$root/etc/hosts" 127.0.1.1
  [[ $(cat "$root/etc/machine-id") =~ ^[0-9a-f]{32}$ ]] || fail "machine-id isn't 32 hex digits"
}

test_stamp_gives_each_computer_its_own_machine_id() {
  setup_stamp
  run_stamp vision-front
  local front
  front=$(cat "$TMP/out/root/etc/machine-id")
  rm -rf "$TMP/out"
  run_stamp vision-back
  [[ $front != "$(cat "$TMP/out/root/etc/machine-id")" ]] || fail "two computers share a machine ID"
}

test_stamp_writes_the_robot_network_profile() {
  setup_stamp
  run_stamp vision-front
  local profile=$TMP/out/root/etc/NetworkManager/system-connections/robot.nmconnection
  assert_file "$profile"
  # NetworkManager ignores a profile others can read.
  assert_mode "$profile" 600
  assert_contains "$profile" 'type=ethernet'
  assert_contains "$profile" 'method=manual'
  # FRC's documented netmask and gateway for on-robot devices.
  assert_contains "$profile" 'address1=10.12.34.11/24,10.12.34.4'
  assert_contains "$profile" 'dad-timeout=3000'
  assert_contains "$profile" 'autoconnect-retries=0'
  grep -Eq '^uuid=[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$profile" ||
    fail "the profile's uuid isn't a UUID"
}


test_stamp_uses_the_tables_port_unless_the_computer_has_its_own() {
  setup_stamp
  run_stamp vision-front
  assert_eq "$(yq -r '.agentPort' "$TMP/out/root/etc/coprocessor/stamp.json")" 5808
  yq -i 'del(.agentPort)' "$TMP/team/coprocessors.yaml"
  run_stamp vision-front
  assert_eq "$(yq -r '.agentPort' "$TMP/out/root/etc/coprocessor/stamp.json")" 5808 "the default"
}






test_stamp_installs_the_teams_public_keys_without_their_comments() {
  setup_stamp
  printf '# the team laptop\n\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherExampleKey mentor@example.org\n' \
    >>"$TMP/team/authorized_keys"
  run_stamp vision-front
  local keys=$TMP/out/root/home/photon/.ssh/authorized_keys
  assert_eq "$(cat "$keys")" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTestsOnly
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherExampleKey" "authorized_keys"
  assert_mode "$keys" 644
  assert_mode "$TMP/out/root/home/photon/.ssh" 755
}

test_stamp_without_keys_leaves_ssh_closed() {
  setup_stamp
  run_stamp vision-front
  rm "$TMP/team/authorized_keys"
  run_stamp vision-front
  assert_no_file "$TMP/out/root/home/photon/.ssh/authorized_keys"
}

test_stamp_refuses_a_private_key() {
  setup_stamp
  # Built here, so the test file itself never looks like a key to a secret scanner.
  local kind="PRIV""ATE"
  printf -- '-----BEGIN OPENSSH %s KEY-----\nabc\n-----END OPENSSH %s KEY-----\n' "$kind" "$kind" \
    >"$TMP/team/authorized_keys"
  assert_fails "private key" run_stamp vision-front
}

test_stamp_refuses_a_line_that_isnt_a_public_key() {
  setup_stamp
  echo 'my password is hunter2' >>"$TMP/team/authorized_keys"
  assert_fails "isn't an SSH public key" run_stamp vision-front
}

test_stamp_is_repeatable() {
  setup_stamp
  run_stamp vision-front
  local first
  first=$(tree_digest "$TMP/out")
  run_stamp vision-front
  assert_eq "$(tree_digest "$TMP/out")" "$first" "the second stamp's files"
}

test_stamp_refuses_a_computer_not_in_the_table() {
  setup_stamp
  assert_fails "no computer named 'vision-side'" run_stamp vision-side
}

test_stamp_refuses_team_zero() {
  setup_stamp
  yq -i '.team = 0' "$TMP/team/coprocessors.yaml"
  assert_fails "set your team's" run_stamp vision-front
}

test_stamp_refuses_addresses_outside_frcs_range() {
  setup_stamp
  yq -i '.computers[0].address = 5' "$TMP/team/coprocessors.yaml"
  assert_fails "outside FRC's range" run_stamp vision-front
  yq -i '.computers[0].address = 20' "$TMP/team/coprocessors.yaml"
  assert_fails "outside FRC's range" run_stamp vision-front
  yq -i '.computers[0].address = 19' "$TMP/team/coprocessors.yaml"
  run_stamp vision-front
}

test_stamp_refuses_two_computers_at_one_address() {
  setup_stamp
  yq -i '.computers[1].address = 11' "$TMP/team/coprocessors.yaml"
  assert_fails "two computers have the address 11" run_stamp vision-front
}

test_stamp_refuses_two_computers_with_one_name() {
  setup_stamp
  yq -i '.computers[1].name = "vision-front"' "$TMP/team/coprocessors.yaml"
  assert_fails "two computers are named vision-front" run_stamp vision-front
}

# Numbers are written plainly: bash would read 0254 as octal, and 09 not at all.
test_stamp_refuses_numbers_with_leading_zeros() {
  setup_stamp
  local table=$TMP/team/coprocessors.yaml
  sed -i 's/^team: 1234$/team: 0254/' "$table"
  assert_fails "team '0254' isn't a team number" run_stamp vision-front
  sed -i 's/^team: 0254$/team: 254/; s/address: 11$/address: 09/' "$table"
  assert_fails "address '09' is outside" run_stamp vision-front
  sed -i 's/address: 09$/address: 9/' "$table"
  run_stamp vision-front
  assert_eq "$(yq -r '.address' "$TMP/out/root/etc/coprocessor/stamp.json")" 10.2.54.9
}

test_stamp_refuses_a_team_number_too_big() {
  setup_stamp
  yq -i '.team = 25600' "$TMP/team/coprocessors.yaml"
  assert_fails "isn't a team number" run_stamp vision-front
}

test_stamp_refuses_a_port_that_isnt_one() {
  setup_stamp
  local table=$TMP/team/coprocessors.yaml port
  for port in 0 65536 08080 '"http"'; do
    yq -i ".agentPort = $port" "$table"
    assert_fails "agentPort" run_stamp vision-front
  done
  yq -i '.agentPort = 5808 | .computers[1].agentPort = 70000' "$table"
  assert_fails "vision-back's agentPort '70000'" run_stamp vision-front
}

test_stamp_refuses_cameras_that_arent_a_list_of_names() {
  setup_stamp
  local table=$TMP/team/coprocessors.yaml
  yq -i '.computers[0].cameras = "front-left"' "$table"
  assert_fails "cameras must be a list" run_stamp vision-front
  yq -i '.computers[0].cameras = ["front/left"]' "$table"
  assert_fails "cameras must each be a name" run_stamp vision-front
  yq -i '.computers[0].cameras = [{"name": "front"}]' "$table"
  assert_fails "cameras must each be a name" run_stamp vision-front
  yq -i '.computers[0].cameras = [""]' "$table"
  assert_fails "cameras must each be a name" run_stamp vision-front
}


test_stamp_refuses_a_name_that_cant_be_a_hostname() {
  setup_stamp
  yq -i '.computers[1].name = "Vision_Back"' "$TMP/team/coprocessors.yaml"
  assert_fails "can't be a computer's name" run_stamp vision-front
}

test_stamp_refuses_an_unknown_board() {
  setup_stamp
  yq -i '.computers[0].image.board = "raspberry-pi-5"' "$TMP/team/coprocessors.yaml"
  assert_fails "isn't one of" run_stamp vision-front
}




test_stamp_refuses_another_yq() {
  setup_stamp
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "yq 3.4.3"\n' >"$TMP/bin/yq"
  chmod +x "$TMP/bin/yq"
  PATH=$TMP/bin:$PATH assert_fails "mikefarah's yq" run_stamp vision-front
}

test_stamp_writes_the_agents_configuration() {
  setup_stamp
  run_stamp vision-front
  cmp -s "$TMP/out/root/etc/frc-coprocessor/agent.json" "$TMP/agent-configs/vision-front.json" ||
    fail "the agent's configuration wasn't written"
  assert_mode "$TMP/out/root/etc/frc-coprocessor/agent.json" 644
}

test_stamp_refuses_another_computers_agent_configuration() {
  setup_stamp
  mkdir -p "$TMP/agent-configs"
  echo '{"name": "vision-back", "packs": []}' >"$TMP/agent-configs/vision-front.json"
  assert_fails "the agent configuration of 'vision-back', not vision-front" run_stamp vision-front
}

test_stamp_writes_the_stamp_twice() {
  setup_stamp
  run_stamp vision-back --stamp-out "$TMP/stamp.json" --built-at 2027-01-10T18:30:00Z
  local stamp=$TMP/out/root/etc/coprocessor/stamp.json
  assert_file "$stamp"
  cmp -s "$stamp" "$TMP/out/coproc/stamp.json" || fail "COPROC's copy differs from the root's"
  cmp -s "$stamp" "$TMP/stamp.json" || fail "--stamp-out differs from the root's"
  assert_eq "$(yq -r '.name' "$stamp")" vision-back
  assert_eq "$(yq -r '.address' "$stamp")" 10.12.34.12
  assert_eq "$(yq -r '.team' "$stamp")" 1234
  assert_eq "$(yq -r '.agentPort' "$stamp")" 5809 "the computer's own port"
  assert_eq "$(yq -r '.version' "$stamp")" coprocessors-1
  assert_eq "$(yq -r '.builtAt' "$stamp")" 2027-01-10T18:30:00Z
  assert_eq "$(yq -r '.recipeHash' "$stamp")" 2222222222222222222222222222222222222222222222222222222222222222
  # The labels: --label's, then the recipe's stamp step's (the settings hash; vision-back has none),
  # sorted by name.
  assert_eq "$(yq -o=json -I=0 '.labels' "$stamp")" \
    '{"photonvisionVersion":"v2027.0.0-alpha-2","settingsHash":""}'
  # The members of Spotter's Stamp record, less what the agent adds as it answers.
  assert_eq "$(yq -r 'keys | join(" ")' "$stamp")" \
    "name team address version recipeHash builtAt labels agentPort"
  assert_contains "$TMP/out/coproc/README.txt" "vision-back, 10.12.34.12"
}

test_stamp_refuses_a_label_that_isnt_one() {
  setup_stamp
  assert_fails "isn't NAME=VALUE" run_stamp vision-front --label 'no value'
  assert_fails "isn't NAME=VALUE" run_stamp vision-front --label '9=x'
  assert_fails "isn't a time in UTC" run_stamp vision-front --built-at yesterday
}

test_stamp_makes_the_folders_datas_bind_mounts_need() {
  setup_stamp
  run_stamp vision-back
  assert_mode "$TMP/out/data/journal" 2755
  assert_mode "$TMP/out/data/ssh" 700
}

test_stamp_needs_the_agents_configuration() {
  setup_stamp
  assert_fails "no agent configuration at" run_stamp vision-front --agent-config "$TMP/none.json"
}
