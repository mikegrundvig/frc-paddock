# shellcheck shell=bash
# plan.sh: the build's inputs checked before anything is downloaded, and what the images get
# written for the jobs after it.

# Runs the copy's plan.sh (make_paddock_copy) on make_team's input, printing what it outputs (not
# into Actions' $GITHUB_OUTPUT, when the tests run in Actions).
run_plan() {
  GITHUB_OUTPUT='' "$TMP/paddock/engine/plan.sh" --config "$TMP/team/paddock.yaml" --repo "$TMP/team" "$@" 2>&1
}

# A value from plan.sh's name=value output.
output() {
  sed -n "s/^$1=//p" "$TMP/plan.out"
}

setup_plan() {
  need_yq
  make_team
  make_paddock_copy
}

test_plan_lists_the_boards_and_computers_to_build() {
  setup_plan
  run_plan --sha 0123456789abcdef0123456789abcdef01234567 >"$TMP/plan.out"
  assert_eq "$(output team)" 1234
  assert_eq "$(output recipe)" photonvision-orangepi "the default recipe"
  assert_eq "$(output runner)" ubuntu-24.04-arm
  assert_eq "$(output version)" "$(yq -p json -r '.version' "$RECIPE/photonvision.lock")"
  assert_eq "$(output version-label)" photonvisionVersion
  assert_eq "$(output release)" build-0123456789ab
  assert_eq "$(output publish)" false
  [[ $(output recipe-hash) =~ ^[0-9a-f]{64}$ ]] || fail "no recipe hash"
  assert_eq "$(output computers)" '[{"hostname":"vision-front","board":"orangepi-5"},{"hostname":"vision-back","board":"orangepi-5-plus"}]'
  output boards >"$TMP/boards.json"
  assert_eq "$(yq -p json -o yaml -r '.[].board' "$TMP/boards.json" | paste -sd ' ')" "orangepi-5 orangepi-5-plus"
  assert_eq "$(yq -p json -o yaml -r '.[0].sha256' "$TMP/boards.json")" edf2bda3032579d759de46aab0e8094cfd3de3586ba764b663470d2b80351cb7
  assert_eq "$(yq -p json -o yaml -r '.[1].minimumFreeMb' "$TMP/boards.json")" 1024
}

test_plan_writes_what_the_images_get() {
  setup_plan
  mkdir -p "$TMP/team/bin"
  printf '#!/bin/sh\necho checked\n' >"$TMP/team/bin/check.sh"
  yq -i '.files += [{"path": "bin/check.sh", "destination": "/opt/team/check.sh", "mode": 755}]' \
    "$TMP/team/paddock.yaml"
  run_plan --sha 0123456 --software "$TMP/software" >"$TMP/plan.out"
  assert_eq "$(cat "$TMP/software/packages.list")" \
    "1111111111111111111111111111111111111111111111111111111111111111 https://example.org/releases/example-tool_1.0.0_arm64.deb"
  assert_eq "$(cat "$TMP/software/files/files.list")" "0644 /etc/example/packs/example.yaml 0
0755 /opt/team/check.sh 1"
  cmp -s "$TMP/software/files/0" "$TMP/team/packs/example.yaml" || fail "the first file wasn't copied"
  cmp -s "$TMP/software/files/1" "$TMP/team/bin/check.sh" || fail "the second file wasn't copied"
  # A second plan replaces what the first wrote.
  yq -i 'del(.files) | del(.packages)' "$TMP/team/paddock.yaml"
  run_plan --sha 0123456 --software "$TMP/software" >"$TMP/plan.out"
  assert_eq "$(wc -c <"$TMP/software/packages.list")" 0 "the packages' list's size"
  assert_eq "$(ls "$TMP/software/files")" files.list
}

test_plan_names_every_problem_in_the_input_at_once() {
  setup_plan
  yq -i '.team = 0 | .computers[0].address = 30 | .computers[1].board = "raspberry-pi-5"' \
    "$TMP/team/paddock.yaml"
  local output
  output=$(run_plan --release coprocessors-1 || true)
  [[ $output == *"has 3 problems"* ]] || fail "not every problem at once: $output"
  [[ $output == *"team '0' isn't a team number"* ]] || fail "no team problem: $output"
  [[ $output == *"vision-front's address '30' is outside"* ]] || fail "no address problem: $output"
  [[ $output == *"vision-back's board 'raspberry-pi-5' isn't one of the recipe's"* ]] ||
    fail "no board problem: $output"
}

test_plan_publishes_a_named_release() {
  setup_plan
  run_plan --release coprocessors-2027.1 >"$TMP/plan.out"
  assert_eq "$(output release)" coprocessors-2027.1
  assert_eq "$(output publish)" true
}

test_plan_takes_the_recipe_from_the_caller() {
  setup_plan
  assert_fails "no recipe named 'nothing-here'" run_plan --release coprocessors-1 --recipe nothing-here
  assert_fails "isn't a recipe's name" run_plan --release coprocessors-1 --recipe ../engine
  run_plan --release coprocessors-1 --recipe photonvision-orangepi >"$TMP/plan.out"
  assert_eq "$(output recipe)" photonvision-orangepi
}

test_plan_checks_the_lock_against_the_robot_codes_version() {
  setup_plan
  echo '{"fileName": "photonlib.json", "version": "v2026.3.4"}' >"$TMP/photonlib.json"
  assert_fails "but the robot code uses v2026.3.4" \
    run_plan --release coprocessors-1 --vendordep "$TMP/photonlib.json"
  yq -i -p json -o json ".version = \"$(yq -p json -r '.version' "$RECIPE/photonvision.lock")\"" \
    "$TMP/photonlib.json"
  run_plan --release coprocessors-1 --vendordep "$TMP/photonlib.json" >/dev/null
}

test_plan_refuses_a_placeholder_checksum() {
  setup_plan
  local lock=$TMP/paddock/recipes/photonvision-orangepi/photonvision.lock
  yq -i -p json -o json '.images.orangepi-5.sha256 = "PLACEHOLDER: archive the image first"' "$lock"
  assert_fails "orangepi-5's base image's sha256 is missing or a placeholder" run_plan --release coprocessors-1
}

test_plan_refuses_another_boards_base_image() {
  setup_plan
  local lock=$TMP/paddock/recipes/photonvision-orangepi/photonvision.lock
  yq -i -p json -o json '.images.orangepi-5.url |= sub("opi5.img", "opi5plus.img")' "$lock"
  assert_fails "but Orange Pi 5's is photonvision_opi5.img.xz" run_plan --release coprocessors-1
}

test_plan_refuses_a_bad_release_name() {
  setup_plan
  assert_fails "release name" run_plan --release 'coprocessors-1; rm -rf /'
  assert_fails "a release is named coprocessors-" run_plan --release v2027.1
  # It's each image's IMAGE_VERSION, which is lowercase.
  assert_fails "lowercase" run_plan --release coprocessors-Week1
}

test_plan_changes_its_recipe_hash_with_what_the_images_get() {
  setup_plan
  local hashes=()
  run_plan --sha 0123456 >"$TMP/plan.out"
  hashes+=("$(output recipe-hash)")
  run_plan --sha 0123456 >"$TMP/plan.out"
  assert_eq "$(output recipe-hash)" "${hashes[0]}" "the same inputs' recipe hash"
  echo 'echo hello' >"$TMP/hook.sh"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  hashes+=("$(output recipe-hash)")
  echo 'checks: [another]' >"$TMP/team/packs/example.yaml"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  hashes+=("$(output recipe-hash)")
  yq -i '.files[0].mode = "0600"' "$TMP/team/paddock.yaml"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  hashes+=("$(output recipe-hash)")
  yq -i '.files[0].destination = "/etc/example/other.yaml"' "$TMP/team/paddock.yaml"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  hashes+=("$(output recipe-hash)")
  yq -i '.packages[0].sha256 = "3333333333333333333333333333333333333333333333333333333333333333"' \
    "$TMP/team/paddock.yaml"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  hashes+=("$(output recipe-hash)")
  # The settings and the computers make no common image: they're stamped.
  yq -i '.computers[0].address = 13' "$TMP/team/paddock.yaml"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  assert_eq "$(output recipe-hash)" "${hashes[5]}" "the hash after a computer's address changed"
  assert_eq "$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l)" 6 \
    "different hashes: the hook, a file's content, mode, and destination, and a package each change it"
}
