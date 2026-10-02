# shellcheck shell=bash
# Paddock's input (paddock.yaml), checked whole by lib/common.sh's check_config: what it accepts,
# and every problem it names, all at once.

setup_config() {
  need_yq
  make_team
}

# Checks make_team's input (or the file given) for the PhotonVision recipe, with the team's
# repository.
run_check() {
  bash -c '. "$1/lib/common.sh"; load_recipe "$2"; check_config "$3" "$4"' _ \
    "$ENGINE" "$RECIPE" "${1:-$TMP/team/paddock.yaml}" "$TMP/team" 2>&1
}

# Edits the input with a yq expression.
edit() {
  yq -i "$1" "$TMP/team/paddock.yaml"
}

test_config_accepts_the_starters_input() {
  setup_config
  run_check
  # Packages and files are optional: a team may list none.
  edit 'del(.packages) | del(.files)'
  run_check
  edit '.packages = [] | .files = []'
  run_check
}

test_config_lists_every_problem_at_once() {
  setup_config
  edit '.team = 0 | .computers[0].hostname = "Vision_Front" | .computers[1].address = 20
    | .computers[1].board = "raspberry-pi-5" | .packages[0].url = "http://example.org/x.deb"
    | .files[0].mode = "rw-r--r--"'
  local output
  output=$(run_check || true)
  [[ $output == *"has 6 problems:"* ]] || fail "not every problem: $output"
  local expected
  for expected in "team '0' isn't a team number" \
    "computers[0]: 'Vision_Front' can't be a hostname" \
    "vision-back's address '20' is outside FRC's range for on-robot devices, 6 to 19" \
    "vision-back's board 'raspberry-pi-5' isn't one of the recipe's: orangepi-5" \
    "packages[0]: url 'http://example.org/x.deb' isn't the https:// address of a .deb" \
    "files[0]: mode 'rw-r--r--' isn't a file's mode in octal"; do
    [[ $output == *"  - $expected"* ]] || fail "doesn't say \"$expected\": $output"
  done
}

test_config_refuses_unknown_and_repeated_keys() {
  setup_config
  edit '.agentPort = 5808 | .computers[0].cameras = ["front"] | .packages[0].name = "tool"
    | .files[0].owner = "root"'
  printf 'team: 1234\n' >>"$TMP/team/paddock.yaml"
  local output
  output=$(run_check || true)
  for expected in "paddock.yaml: unknown key 'agentPort' (it takes: team, computers, packages, files)" \
    "paddock.yaml: 'team' is given twice" \
    "computers[0]: unknown key 'cameras' (it takes: hostname, address, board)" \
    "packages[0]: unknown key 'name'" "files[0]: unknown key 'owner'"; do
    [[ $output == *"$expected"* ]] || fail "doesn't say \"$expected\": $output"
  done
}

test_config_refuses_what_isnt_an_input() {
  setup_config
  printf 'team: [1234\n' >"$TMP/bad.yaml"
  assert_fails "isn't YAML" run_check "$TMP/bad.yaml"
  printf -- '- team: 1234\n' >"$TMP/list.yaml"
  assert_fails "expected team, computers, packages, and files" run_check "$TMP/list.yaml"
  assert_fails "no input at" run_check "$TMP/none.yaml"
  printf 'team: 1234\n' >"$TMP/empty.yaml"
  assert_fails "computers must be a list" run_check "$TMP/empty.yaml"
  printf 'team: 1234\ncomputers: []\n' >"$TMP/none-listed.yaml"
  assert_fails "computers lists none" run_check "$TMP/none-listed.yaml"
}

test_config_refuses_team_numbers_that_arent() {
  setup_config
  local team
  for team in 0 25600 '"1234"' 1234.0 -5; do
    edit ".team = $team"
    assert_fails "isn't a team number" run_check
  done
  # Written plainly: bash would read 0254 as octal.
  sed -i 's/^team: .*/team: 0254/' "$TMP/team/paddock.yaml"
  assert_fails "team '0254' isn't a team number" run_check
  sed -i 's/^team: .*/team: 25599/' "$TMP/team/paddock.yaml"
  run_check
  edit 'del(.team)'
  assert_fails "team '' isn't a team number" run_check
}

test_config_refuses_addresses_outside_frcs_range_or_shared() {
  setup_config
  edit '.computers[0].address = 5'
  assert_fails "vision-front's address '5' is outside FRC's range" run_check
  edit '.computers[0].address = 19'
  run_check
  edit '.computers[0].address = 6'
  run_check
  sed -i 's/address: 6$/address: 09/' "$TMP/team/paddock.yaml"
  assert_fails "address '09' is outside" run_check
  edit '.computers[0].address = 12'
  assert_fails "two computers have the address 12 (vision-front and vision-back)" run_check
  edit '.computers[0].address = "11"'
  assert_fails "address '11' is outside" run_check
  edit 'del(.computers[0].address)'
  assert_fails "vision-front has no address" run_check
}

test_config_refuses_hostnames_that_cant_be_or_are_shared() {
  setup_config
  local name
  for name in Vision-Front vision_front -front front- "vision front"; do
    NAME=$name yq -i '.computers[1].hostname = strenv(NAME)' "$TMP/team/paddock.yaml"
    assert_fails "can't be a hostname" run_check
  done
  edit '.computers[1].hostname = "vision-front"'
  assert_fails "two computers have the hostname vision-front" run_check
  edit 'del(.computers[1].hostname)'
  assert_fails "computers[1] has no hostname" run_check
  edit '.computers[1] = "vision-back"'
  assert_fails "computers[1] must be a computer" run_check
}

test_config_refuses_a_board_the_recipe_doesnt_build() {
  setup_config
  edit 'del(.computers[0].board)'
  assert_fails "vision-front has no board (one of: orangepi-5" run_check
  edit '.computers[0].board = "orangepi-6"'
  assert_fails "vision-front's board 'orangepi-6' isn't one of the recipe's" run_check
}

test_config_checks_each_package() {
  setup_config
  local url
  for url in http://example.org/x.deb https://example.org/x.tar.gz 'https://example.org/x y.deb' \
    'https://example.org/x.deb?token=1' ''; do
    URL=$url yq -i '.packages[0].url = strenv(URL)' "$TMP/team/paddock.yaml"
    assert_fails "isn't the https:// address of a .deb" run_check
  done
  edit '.packages[0].url = "https://example.org/x.deb" | .packages[0].sha256 = "ABC"'
  assert_fails "sha256 'ABC' isn't a SHA-256" run_check
  edit '.packages[0].sha256 = "1111111111111111111111111111111111111111111111111111111111111111"
    | .packages += [.packages[0]]'
  assert_fails "packages[1]: https://example.org/x.deb is listed twice" run_check
  edit '.packages = {"url": "https://example.org/x.deb"}'
  assert_fails "packages must be a list" run_check
}

test_config_checks_each_files_path_in_the_repository() {
  setup_config
  local path
  for path in /etc/passwd ../outside.yaml packs/../packs/example.yaml ./packs/example.yaml \
    'packs/example .yaml' packs/; do
    PATH_=$path yq -i '.files[0].path = strenv(PATH_)' "$TMP/team/paddock.yaml"
    assert_fails "isn't a path in the team's repository" run_check
  done
  edit '.files[0].path = "packs/missing.yaml"'
  assert_fails "files[0]: packs/missing.yaml isn't a file in the team's repository" run_check
  edit '.files[0].path = "packs"'
  assert_fails "files[0]: packs isn't a file" run_check
  # A link could reach outside the repository, into the machine building the images.
  echo 'secret' >"$TMP/outside.txt"
  ln -s ../../outside.txt "$TMP/team/packs/linked.yaml"
  edit '.files[0].path = "packs/linked.yaml"'
  assert_fails "files[0]: packs/linked.yaml isn't a file" run_check
}

test_config_checks_each_files_destination_and_mode() {
  setup_config
  local destination
  for destination in etc/example.yaml /etc/../example.yaml /etc/example/ '/etc/ex ample.yaml' ''; do
    DEST=$destination yq -i '.files[0].destination = strenv(DEST)' "$TMP/team/paddock.yaml"
    assert_fails "isn't a path in the image" run_check
  done
  edit '.files[0].destination = "/data/team.yaml"'
  assert_fails "is on the data partition, which stamping fills" run_check
  for destination in /etc/hostname /etc/os-release /usr/lib/os-release /etc/machine-id; do
    DEST=$destination yq -i '.files[0].destination = strenv(DEST)' "$TMP/team/paddock.yaml"
    assert_fails "is written at stamping" run_check
  done
  edit '.files[0].destination = "/etc/example.yaml" | .files += [.files[0]]'
  assert_fails "files[1]: two files have the destination /etc/example.yaml" run_check
  edit 'del(.files[1])'
  local mode
  for mode in 644 0644 '"0644"' '"755"' 0600; do
    edit ".files[0].mode = $mode"
    run_check
  done
  for mode in 0888 '"u=rw"' 4755 01777 '""' '[644]'; do
    edit ".files[0].mode = $mode"
    assert_fails "isn't a file's mode in octal" run_check
  done
}
