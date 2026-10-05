# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# run-steps.sh, offline on a directory tree: the base checked against the adapters, then the steps
# in order. (In a real image's chroot, packages install with apt and run steps run: the container
# tests and CI's image build cover that.)

setup_steps() {
  need_yq
  make_team
  make_root
  make_inputs
  make_plan
}

run_steps() {
  "$ENGINE/run-steps.sh" --plan "$TMP/plan" --image vision --config-dir "$TMP/team" --inputs "$TMP/inputs" \
    --root "$TMP/root" --offline
}

test_steps_put_files_with_their_modes() {
  setup_steps
  run_steps
  assert_eq "$(cat "$TMP/root/etc/tool/tool.yaml")" 'checks: [example]'
  assert_mode "$TMP/root/etc/tool/tool.yaml" 600
  assert_mode "$TMP/root/opt/team/check.sh" 755
}

test_steps_install_packages() {
  setup_steps
  run_steps
  assert_file "$TMP/root/usr/bin/example-tool"
}

test_steps_run_in_order() {
  setup_steps
  local output lines a b c d
  output=$(run_steps 2>&1)
  # The file step, the package, the script (logged offline), then the second file.
  lines=$(grep -nE 'step 1:|installing|step 3: would run setup/vision.sh|step 4:' <<<"$output" | cut -d: -f1 | paste -sd ' ')
  read -r a b c d <<<"$lines"
  if [[ -z $d ]] || ! ((a < b && b < c && c < d)); then
    fail "out of order: $output"
  fi
}

test_steps_replace_what_was_there() {
  setup_steps
  mkdir -p "$TMP/root/etc/tool"
  echo old >"$TMP/root/etc/tool/tool.yaml"
  run_steps
  assert_eq "$(cat "$TMP/root/etc/tool/tool.yaml")" 'checks: [example]'
}

test_steps_name_everything_the_base_lacks() {
  setup_steps
  rm "$TMP/root/usr/bin/apt-get" "$TMP/root/usr/lib/systemd/systemd"
  local output
  output=$(run_steps 2>&1 || true)
  [[ $output == *"vision's base isn't one its adapters (os:) can build on"* ]] || fail "$output"
  [[ $output == *"no /usr/bin/apt-get"* && $output == *"no systemd"* ]] || fail "not all named: $output"
  assert_no_file "$TMP/root/etc/tool/tool.yaml"
}

test_steps_need_their_packages() {
  setup_steps
  rm "$TMP/inputs/packages"/*
  assert_fails "step 2: package example-tool_1.0.0_arm64.deb isn't in" run_steps
}

test_steps_place_downloads_with_their_modes() {
  setup_steps
  run_steps
  assert_eq "$(cat "$TMP/root/opt/team/model.bin")" 'a model'
  assert_mode "$TMP/root/opt/team/model.bin" 640
}

test_steps_need_their_downloads() {
  setup_steps
  rm "$TMP/inputs/downloads"/*
  assert_fails "step 5: download model.bin isn't in" run_steps
}

test_steps_leave_the_network_adapters_check_for_after_them() {
  setup_steps
  rm "$TMP/root/usr/sbin/NetworkManager"
  run_steps
}

test_steps_refuse_to_run_on_a_machine_outside_a_chroot() {
  setup_steps
  if ((EUID == 0)); then
    skip "runs as root here"
  fi
  assert_fails "run as root, inside the image's chroot" "$ENGINE/run-steps.sh" --plan "$TMP/plan" \
    --image vision --config-dir "$TMP/team" --inputs "$TMP/inputs" --root "$TMP/root"
}

test_steps_refuse_a_file_onto_a_folder() {
  setup_steps
  mkdir -p "$TMP/root/etc/tool/tool.yaml"
  assert_fails "step 1: /etc/tool/tool.yaml is a folder in the image: give the file's full path" run_steps
}

# No package starts a service while the steps run; afterwards the base's policy-rc.d (or none) is back.
test_steps_leave_the_bases_policy_rc_d() {
  setup_steps
  run_steps
  assert_no_file "$TMP/root/usr/sbin/policy-rc.d"
  printf '#!/bin/sh\nexit 0\n' >"$TMP/root/usr/sbin/policy-rc.d"
  run_steps
  assert_eq "$(cat "$TMP/root/usr/sbin/policy-rc.d")" $'#!/bin/sh\nexit 0'
  assert_no_file "$TMP/root/usr/sbin/policy-rc.d.paddock-saved"
}

test_steps_leave_the_bases_policy_rc_d_when_a_step_fails() {
  setup_steps
  rm "$TMP/inputs/downloads"/*
  run_steps 2>/dev/null && fail "the steps passed without their download"
  assert_no_file "$TMP/root/usr/sbin/policy-rc.d"
}
