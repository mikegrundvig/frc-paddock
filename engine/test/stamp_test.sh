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
  # Every computer in the input, by its robot address.
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

test_stamp_labels_the_image_in_os_release() {
  setup_stamp
  run_stamp vision-front --label board=orangepi-5 --built-at 2027-01-10T18:30:00Z
  local os_release=$TMP/out/root/usr/lib/os-release
  # Written through /etc/os-release's link, into the file it names; the base image's own lines kept.
  [[ -L $TMP/out/root/etc/os-release ]] || fail "/etc/os-release is no longer a link"
  assert_contains "$os_release" 'ID=debian'
  assert_eq "$(grep -E '^(IMAGE_|PADDOCK_)' "$os_release")" "IMAGE_ID=\"paddock-photonvision-orangepi\"
IMAGE_VERSION=\"coprocessors-1\"
PADDOCK_BOARD=\"orangepi-5\"
PADDOCK_BUILT_AT=\"2027-01-10T18:30:00Z\"
PADDOCK_PHOTONVISION_VERSION=\"v2027.0.0-alpha-2\"
PADDOCK_RECIPE=\"photonvision-orangepi\"
PADDOCK_RECIPE_HASH=\"2222222222222222222222222222222222222222222222222222222222222222\"
PADDOCK_SETTINGS_HASH=\"$(yq -r '.labels.settingsHash' "$TMP/out/coproc/stamp.json")\""
  assert_mode "$os_release" 644
  # As a shell reads it, as os-release(5) allows.
  # shellcheck source=/dev/null
  assert_eq "$(. "$os_release" && echo "$IMAGE_VERSION $PADDOCK_BOARD")" "coprocessors-1 orangepi-5"
}

test_stamp_quotes_a_labels_value_as_os_release_does() {
  setup_stamp
  run_stamp vision-front --label 'note=a "quoted" $HOME `cmd` \ value'
  local os_release=$TMP/out/root/usr/lib/os-release
  # shellcheck disable=SC2016,SC1090 # literally; the image's file
  assert_eq "$(. "$os_release" && echo "$PADDOCK_NOTE")" 'a "quoted" $HOME `cmd` \ value'
}

test_stamp_relabels_an_image_without_doubling_its_labels() {
  setup_stamp
  run_stamp vision-front
  run_stamp vision-back --release coprocessors-2
  local os_release=$TMP/out/root/usr/lib/os-release
  assert_eq "$(grep -c '^IMAGE_VERSION=' "$os_release")" 1 "IMAGE_VERSION lines"
  assert_contains "$os_release" 'IMAGE_VERSION="coprocessors-2"'
  assert_eq "$(grep -c '^# Paddock: ' "$os_release")" 1 "Paddock's comment lines"
}

test_stamp_labels_an_os_release_that_isnt_a_link() {
  setup_stamp
  mkdir -p "$TMP/out/root/etc"
  printf 'ID=debian\nIMAGE_ID="someone-elses"\n' >"$TMP/out/root/etc/os-release"
  run_stamp vision-front
  assert_contains "$TMP/out/root/etc/os-release" 'IMAGE_ID="paddock-photonvision-orangepi"'
  assert_not_contains "$TMP/out/root/etc/os-release" someone-elses
  assert_not_contains "$TMP/out/root/usr/lib/os-release" PADDOCK_
}

test_stamp_refuses_an_os_release_outside_the_image() {
  setup_stamp
  mkdir -p "$TMP/out/root/etc"
  echo 'ID=host' >"$TMP/host-os-release"
  ln -s ../../../host-os-release "$TMP/out/root/etc/os-release"
  assert_fails "links outside the image" run_stamp vision-front
  assert_eq "$(cat "$TMP/host-os-release")" "ID=host" "the file outside"
}

test_stamp_refuses_labels_that_make_one_field() {
  setup_stamp
  assert_fails "make one os-release field: PADDOCK_RECIPE_HASH" run_stamp vision-front --label recipeHash=x
  assert_fails "PADDOCK_A_B" run_stamp vision-front --label a.b=1 --label a-b=2
}

test_stamp_writes_its_record_on_coproc_and_not_the_root() {
  setup_stamp
  run_stamp vision-back --stamp-out "$TMP/stamp.json" --built-at 2027-01-10T18:30:00Z
  local stamp=$TMP/out/coproc/stamp.json
  assert_file "$stamp"
  cmp -s "$stamp" "$TMP/stamp.json" || fail "--stamp-out differs from COPROC's"
  assert_no_file "$TMP/out/root/etc/coprocessor/stamp.json"
  assert_eq "$(yq -r '.hostname' "$stamp")" vision-back
  assert_eq "$(yq -r '.address' "$stamp")" 10.12.34.12
  assert_eq "$(yq -r '.team' "$stamp")" 1234
  assert_eq "$(yq -r '.release' "$stamp")" coprocessors-1
  assert_eq "$(yq -r '.recipe' "$stamp")" photonvision-orangepi
  assert_eq "$(yq -r '.builtAt' "$stamp")" 2027-01-10T18:30:00Z
  assert_eq "$(yq -r '.recipeHash' "$stamp")" 2222222222222222222222222222222222222222222222222222222222222222
  # The labels: --label's, then the recipe's stamp step's (the settings hash; vision-back has none),
  # sorted by name.
  assert_eq "$(yq -o=json -I=0 '.labels' "$stamp")" \
    '{"photonvisionVersion":"v2027.0.0-alpha-2","settingsHash":""}'
  assert_eq "$(yq -r 'keys | join(" ")' "$stamp")" \
    "hostname team address release recipe recipeHash builtAt labels"
  assert_contains "$TMP/out/coproc/README.txt" "vision-back, 10.12.34.12"
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

test_stamp_refuses_a_computer_not_in_the_input() {
  setup_stamp
  assert_fails "no computer with the hostname 'vision-side'" run_stamp vision-side
}

test_stamp_checks_the_input_whole() {
  setup_stamp
  yq -i '.team = 0 | .computers[1].address = 11' "$TMP/team/paddock.yaml"
  assert_fails "has 2 problems" run_stamp vision-front
}

test_stamp_refuses_another_yq() {
  setup_stamp
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "yq 3.4.3"\n' >"$TMP/bin/yq"
  chmod +x "$TMP/bin/yq"
  PATH=$TMP/bin:$PATH assert_fails "mikefarah's yq" run_stamp vision-front
}

test_stamp_refuses_a_label_or_release_that_isnt_one() {
  setup_stamp
  assert_fails "isn't NAME=VALUE" run_stamp vision-front --label 'no value'
  assert_fails "isn't NAME=VALUE" run_stamp vision-front --label '9=x'
  assert_fails "isn't a time in UTC" run_stamp vision-front --built-at yesterday
  assert_fails "lowercase letters" run_stamp vision-front --release Coprocessors-1
}

test_stamp_makes_the_folders_datas_bind_mounts_need() {
  setup_stamp
  run_stamp vision-back
  assert_mode "$TMP/out/data/journal" 2755
  assert_mode "$TMP/out/data/ssh" 700
}
