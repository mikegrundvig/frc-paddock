# shellcheck shell=bash
# The PhotonVision recipe's stamp step (stamp-data.sh), as the engine's stamp.sh runs it: the
# settings database built from the committed rows, and the settings hash it labels the stamp with.

setup_stamp() {
  need_yq
  make_team
  make_settings_tool
}

test_stamp_builds_the_settings_database_from_the_committed_rows() {
  setup_stamp
  run_stamp vision-front
  local db=$TMP/out/data/photonvision_config/photon.sqlite
  assert_file "$db"
  assert_contains "$db" 'SQLite format 3'
  assert_contains "$db" '"calibration": [1, 2, 3]'
  # The tool got the computer's rows, the empty database, and where to write.
  assert_eq "$(sed -n 1p "$TMP/tool.log")" "$TMP/team/settings/vision-front"
  assert_eq "$(sed -n 2p "$TMP/tool.log")" "$TMP/inputs/empty-photon.sqlite"
  assert_eq "$(sed -n 3p "$TMP/tool.log")" "$db"
  # The stamp carries the tool's hash.
  local expected
  expected=$(cd "$TMP/team/settings/vision-front" && find . -type f -print0 | LC_ALL=C sort -z |
    xargs -0 cat | sha256sum | cut -c1-64)
  assert_eq "$(yq -r '.labels.settingsHash' "$TMP/out/coproc/stamp.json")" "$expected"
  assert_mode "$TMP/out/data/photonvision_config" 755
}

test_stamp_without_settings_leaves_photonvision_its_defaults() {
  setup_stamp
  mkdir -p "$TMP/team/settings/vision-back"
  : >"$TMP/team/settings/vision-back/.gitkeep"
  run_stamp vision-back
  assert_no_file "$TMP/out/data/photonvision_config/photon.sqlite"
  assert_no_file "$TMP/tool.log"
  # Neither the tool nor the empty database is needed then.
  rm -rf "$TMP/out" "$TMP/inputs"
  run_stamp vision-back
  assert_eq "$(yq -r '.labels.settingsHash' "$TMP/out/coproc/stamp.json")" ""
}

test_stamp_needs_the_settings_tool_for_committed_settings() {
  setup_stamp
  rm -rf "$TMP/inputs"
  assert_fails "needs settings-tool" run_stamp vision-front
}

test_stamp_fails_when_the_settings_tool_fails() {
  setup_stamp
  printf '#!/bin/sh\necho "no such table: global" >&2\nexit 3\n' >"$TMP/inputs/settings-tool"
  assert_fails "settings tool failed" run_stamp vision-front
}

# A JVM can print its own warnings to standard output before the tool's hash.
test_stamp_takes_the_settings_tools_last_line_as_the_hash() {
  setup_stamp
  mv "$TMP/inputs/settings-tool" "$TMP/inputs/settings-tool-quiet"
  printf '#!/bin/sh\necho "[0.002s][warning][os,container] Cgroup memory controller path moved"\nexec "%s" "$@"\n' \
    "$TMP/inputs/settings-tool-quiet" >"$TMP/inputs/settings-tool"
  chmod +x "$TMP/inputs/settings-tool"
  local output
  output=$(run_stamp vision-front 2>&1)
  [[ $output == *"also said: [0.002s][warning]"* ]] || fail "the extra line wasn't passed on: $output"
  [[ $(yq -r '.labels.settingsHash' "$TMP/out/coproc/stamp.json") =~ ^[0-9a-f]{64}$ ]] ||
    fail "settingsHash isn't the tool's hash"
}

test_stamp_refuses_a_settings_hash_that_isnt_one() {
  setup_stamp
  # shellcheck disable=SC2016 # the stand-in's own $2 and $3
  printf '#!/bin/sh\ncp "$2" "$3"\necho abc\n' >"$TMP/inputs/settings-tool"
  assert_fails "not a sha256" run_stamp vision-front
}

