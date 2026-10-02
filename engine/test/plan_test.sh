# shellcheck shell=bash
# plan.sh: the build's inputs checked before anything is downloaded.

# Runs the copy's plan.sh (make_paddock_copy) on make_team's table, printing what it outputs (not
# into Actions' $GITHUB_OUTPUT, when the tests run in Actions).
run_plan() {
  GITHUB_OUTPUT='' "$TMP/paddock/engine/plan.sh" --table "$TMP/team/coprocessors.yaml" "$@" 2>&1
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
  assert_eq "$(output computers)" '[{"name":"vision-front","board":"orangepi-5"},{"name":"vision-back","board":"orangepi-5-plus"}]'
  output boards >"$TMP/boards.json"
  assert_eq "$(yq -p json -o yaml -r '.[].board' "$TMP/boards.json" | paste -sd ' ')" "orangepi-5 orangepi-5-plus"
  assert_eq "$(yq -p json -o yaml -r '.[0].sha256' "$TMP/boards.json")" edf2bda3032579d759de46aab0e8094cfd3de3586ba764b663470d2b80351cb7
  assert_eq "$(yq -p json -o yaml -r '.[0].rootLocation' "$TMP/boards.json")" partition=1
  assert_eq "$(yq -p json -o yaml -r '.[1].minimumFreeMb' "$TMP/boards.json")" 1024
}

test_plan_takes_the_recipe_from_the_caller_else_the_table() {
  setup_plan
  yq -i '.image.recipe = "nothing-here"' "$TMP/team/coprocessors.yaml"
  assert_fails "no recipe named 'nothing-here'" run_plan --release coprocessors-1
  run_plan --release coprocessors-1 --recipe photonvision-orangepi >"$TMP/plan.out"
  assert_eq "$(output recipe)" photonvision-orangepi
  assert_fails "isn't a recipe's name" run_plan --release coprocessors-1 --recipe ../engine
}

test_plan_publishes_a_named_release() {
  setup_plan
  run_plan --release coprocessors-2027.1 >"$TMP/plan.out"
  assert_eq "$(output release)" coprocessors-2027.1
  assert_eq "$(output publish)" true
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

test_plan_refuses_a_placeholder_for_spotters_agent() {
  setup_plan
  yq -i -p json -o json '.debs.arm64.sha256 = "PLACEHOLDER"' "$TMP/paddock/spotter.lock"
  assert_fails "the agent for arm64's sha256 is missing or a placeholder" run_plan --release coprocessors-1
}

test_plan_refuses_another_boards_base_image() {
  setup_plan
  local lock=$TMP/paddock/recipes/photonvision-orangepi/photonvision.lock
  yq -i -p json -o json '.images.orangepi-5.url |= sub("opi5.img", "opi5plus.img")' "$lock"
  assert_fails "but Orange Pi 5's is photonvision_opi5.img.xz" run_plan --release coprocessors-1
}

test_plan_refuses_a_board_the_recipe_doesnt_build() {
  setup_plan
  yq -i '.computers[0].image.board = "raspberry-pi-5"' "$TMP/team/coprocessors.yaml"
  assert_fails "isn't one of: orangepi-5" run_plan --release coprocessors-1
}

test_plan_refuses_a_bad_release_name() {
  setup_plan
  assert_fails "release name" run_plan --release 'coprocessors-1; rm -rf /'
  assert_fails "a release is named coprocessors-" run_plan --release v2027.1
}

test_plan_changes_its_recipe_hash_with_the_teams_hook_and_packs() {
  setup_plan
  run_plan --sha 0123456 >"$TMP/plan.out"
  local plain
  plain=$(output recipe-hash)
  echo 'echo hello' >"$TMP/hook.sh"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  local hooked
  hooked=$(output recipe-hash)
  [[ $hooked != "$plain" ]] || fail "the hook didn't change the recipe hash"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" >"$TMP/plan.out"
  assert_eq "$(output recipe-hash)" "$hooked" "the same inputs' recipe hash"
  mkdir -p "$TMP/packs/lidar"
  echo 'pack: lidar' >"$TMP/packs/lidar/pack.yaml"
  run_plan --sha 0123456 --hook "$TMP/hook.sh" --pack "$TMP/packs/lidar" >"$TMP/plan.out"
  [[ $(output recipe-hash) != "$hooked" ]] || fail "the team's pack didn't change the recipe hash"
}
