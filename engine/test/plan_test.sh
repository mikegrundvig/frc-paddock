# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# plan.sh: the plan the later jobs follow, readable with bash alone, and what it prints for Actions.

setup_plan() {
  need_yq
  make_team
}

test_plan_writes_each_image() {
  setup_plan
  make_plan
  local env=$TMP/plan/images/vision/image.env
  assert_file "$env"
  (
    . "$env"
    assert_eq "$IMAGE" vision
    assert_eq "$BASE_URL" https://example.org/images/base-arm64.img.xz
    assert_eq "$BASE_SHA256" "$SHA_A"
    assert_eq "$BASE_FORMAT" xz
    assert_eq "$ARCH" arm64
    assert_eq "$GROW_MB" 2048
    assert_eq "$OS_PACKAGES" apt
    assert_eq "$OS_INIT" systemd
    assert_eq "$OS_NETWORK" networkmanager
    assert_eq "$OS_FILESYSTEM" ext4
    assert_eq "$READ_ONLY" yes
    assert_eq "$DATA_MB" 64
    assert_eq "$KEEP" "/var/lib/team /var/log/journal"
    # The defaults, and the adapters' own.
    assert_eq "$RAM" "/tmp /var/tmp /var/log /var/lib/systemd /var/lib/NetworkManager"
  )
  (
    . "$TMP/plan/images/plain/image.env"
    assert_eq "$BASE_FORMAT" img
    assert_eq "$ARCH" amd64
    assert_eq "$GROW_MB" 1024 "the default growth"
    assert_eq "$READ_ONLY" no
    assert_eq "$RAM" ""
  )
}

test_plan_writes_the_steps_in_order() {
  setup_plan
  make_plan
  local steps=$TMP/plan/images/vision/steps.list
  assert_eq "$(wc -l <"$steps")" 5 "steps"
  assert_eq "$(sed -n 1p "$steps")" $'file\tconfig/tool.yaml\t/etc/tool/tool.yaml\t0600'
  assert_eq "$(sed -n 2p "$steps")" $'package\t'"$SHA_1"$'\thttps://example.org/releases/example-tool_1.0.0_arm64.deb'
  assert_eq "$(sed -n 3p "$steps")" $'run\tsetup/vision.sh'
  assert_eq "$(sed -n 4p "$steps")" $'file\tsetup/check.sh\t/opt/team/check.sh\t0755'
  assert_eq "$(sed -n 5p "$steps")" $'download\t'"$SHA_2"$'\thttps://example.org/releases/model.bin\t/opt/team/model.bin\t0640'
  [[ ! -s $TMP/plan/images/plain/steps.list ]] || fail "the plain image has no steps"
}

test_plan_writes_each_computer_and_the_hosts() {
  setup_plan
  make_plan
  (
    . "$TMP/plan/computers/vision-front.env"
    assert_eq "$COMPUTER" vision-front
    assert_eq "$COMPUTER_IMAGE" vision
    assert_eq "$ADDRESS" 10.12.34.11
    assert_eq "$PREFIX" 24
    assert_eq "$GATEWAY" 10.12.34.4
    assert_eq "$DNS" ""
  )
  (
    . "$TMP/plan/computers/bench.env"
    assert_eq "$GATEWAY" ""
    assert_eq "$DNS" "192.168.1.1 1.1.1.1"
  )
  assert_eq "$(cat "$TMP/plan/hosts")" $'10.12.34.11\tvision-front\n10.12.34.12\tvision-back\n192.168.1.50\tbench'
}

test_plan_prints_what_actions_needs() {
  setup_plan
  make_plan --release images-2027.1
  local out=$TMP/plan.out
  assert_contains "$out" "release=images-2027.1"
  assert_contains "$out" "publish=yes"
  assert_contains "$out" 'images=[{"image":"vision","runner":"ubuntu-24.04-arm"},{"image":"plain","runner":"ubuntu-24.04"}]'
  assert_contains "$out" 'computers=[{"hostname":"vision-front","image":"vision"},{"hostname":"vision-back","image":"vision"},{"hostname":"bench","image":"plain"}]'
  (
    . "$TMP/plan/plan.env"
    assert_eq "$RELEASE" images-2027.1
    assert_eq "$PUBLISH" yes
    assert_eq "$COMMIT" 0123456789abcdef0123456789abcdef01234567
    assert_eq "$BUILT_AT" 2027-01-10T18:30:00Z
    assert_eq "$REPOSITORY" team/robot-images
  )
}

test_plan_without_a_release_names_the_build_by_its_commit() {
  setup_plan
  make_plan
  assert_contains "$TMP/plan.out" "release=build-0123456789ab"
  assert_contains "$TMP/plan.out" "publish=no"
}

test_plan_refuses_a_release_name_that_cant_label_an_image() {
  setup_plan
  assert_fails "release name 'Images 2027'" make_plan --release "Images 2027"
}

test_plan_leaves_out_an_image_no_computer_uses() {
  setup_plan
  edit_team 'del(.computers[2])'
  local output
  output=$(make_plan 2>&1)
  [[ $output == *"image plain: no computer uses it"* ]] || fail "it doesn't say so: $output"
  assert_no_file "$TMP/plan/images/plain"
  assert_contains "$TMP/plan.out" 'images=[{"image":"vision","runner":"ubuntu-24.04-arm"}]'
}

test_plan_adds_the_images_ram_paths_to_the_defaults() {
  setup_plan
  edit_team '.images.vision["read-only"].ram = ["/srv/cache", "/tmp"]'
  make_plan
  (
    . "$TMP/plan/images/vision/image.env"
    assert_eq "$RAM" "/tmp /var/tmp /var/log /var/lib/systemd /var/lib/NetworkManager /srv/cache"
  )
}

test_plan_gives_a_file_its_default_mode() {
  setup_plan
  edit_team 'del(.images.vision.steps[0].mode)'
  make_plan
  assert_eq "$(sed -n 1p "$TMP/plan/images/vision/steps.list")" $'file\tconfig/tool.yaml\t/etc/tool/tool.yaml\t0644'
}

test_plan_writes_sha256s_in_lower_case_hex() {
  setup_plan
  edit_team ".images.vision.from.sha256 = \"sha256:${SHA_A^^}\" | .images.vision.steps[1].sha256 = \"${SHA_1^^}\""
  make_plan
  (
    . "$TMP/plan/images/vision/image.env"
    assert_eq "$BASE_SHA256" "$SHA_A"
  )
  assert_eq "$(cut -f2 <(sed -n 2p "$TMP/plan/images/vision/steps.list"))" "$SHA_1"
}

test_plan_refuses_an_out_folder_that_isnt_a_plan() {
  setup_plan
  mkdir -p "$TMP/elsewhere"
  echo 'keep me' >"$TMP/elsewhere/notes.txt"
  assert_fails "isn't empty and isn't an earlier plan" "$ENGINE/plan.sh" --config "$TMP/team/paddock.yaml" \
    --out "$TMP/elsewhere" --commit 0123456789abcdef
  assert_file "$TMP/elsewhere/notes.txt"
  # An earlier plan is replaced.
  make_plan
  make_plan
}

test_plan_reads_the_commit_and_its_time_from_git() {
  setup_plan
  need git
  git -C "$TMP/team" init -q
  git -C "$TMP/team" add -A
  GIT_COMMITTER_DATE=2027-01-09T12:00:00Z git -C "$TMP/team" -c user.name=t -c user.email=t@example.org \
    commit -q -m first --date 2027-01-09T12:00:00Z
  git -C "$TMP/team" remote add origin git@github.com:team1234/robot-images.git
  GITHUB_OUTPUT=$TMP/plan.out "$ENGINE/plan.sh" --config "$TMP/team/paddock.yaml" --out "$TMP/plan"
  (
    . "$TMP/plan/plan.env"
    assert_eq "$COMMIT" "$(git -C "$TMP/team" rev-parse HEAD)"
    assert_eq "$BUILT_AT" 2027-01-09T12:00:00Z
    assert_eq "$REPOSITORY" team1234/robot-images "the repository, from its remote"
  )
}

test_plan_takes_paths_from_the_inputs_own_folder() {
  setup_plan
  # The team's input in a folder of the repository: its paths are from that folder.
  mkdir -p "$TMP/repo"
  mv "$TMP/team" "$TMP/repo/images"
  GITHUB_OUTPUT=$TMP/plan.out "$ENGINE/plan.sh" --config "$TMP/repo/images/paddock.yaml" --out "$TMP/plan" \
    --repo "$TMP/repo" --commit 0123456789abcdef
  assert_eq "$(sed -n 1p "$TMP/plan/images/vision/steps.list")" $'file\tconfig/tool.yaml\t/etc/tool/tool.yaml\t0600'
  # A path from the repository's root isn't one from the input's folder.
  yq -i '.images.vision.steps[0].file = "images/config/tool.yaml"' "$TMP/repo/images/paddock.yaml"
  assert_fails "images/config/tool.yaml isn't a file in paddock.yaml's folder" \
    "$ENGINE/plan.sh" --config "$TMP/repo/images/paddock.yaml" --out "$TMP/plan" --commit 0123456789abcdef
}

test_plan_refuses_a_bad_input_before_writing_anything() {
  setup_plan
  edit_team '.computers[0].address = "11"'
  assert_fails "isn't an IPv4 address and prefix" make_plan
  assert_no_file "$TMP/plan"
}

test_plan_copies_each_computers_own_files() {
  need_yq
  make_team
  mkdir -p "$TMP/team/computers/front"
  echo 'fx: 600.0' >"$TMP/team/computers/front/camera.yaml"
  echo 'id: front' >"$TMP/team/computers/front/id.conf"
  edit_team '.computers[0].files = [
    {"file": "computers/front/camera.yaml", "to": "/etc/team/camera.yaml", "mode": "0600"},
    {"file": "computers/front/id.conf", "to": "/etc/team/id.conf"}]'
  make_plan
  local own=$TMP/plan/computers/vision-front.files
  assert_eq "$(cat "$own/list")" $'00\t/etc/team/camera.yaml\t0600\n01\t/etc/team/id.conf\t0644' "the list"
  assert_eq "$(cat "$own/00")" 'fx: 600.0'
  assert_eq "$(cat "$own/01")" 'id: front'
  assert_no_file "$TMP/plan/computers/vision-back.files"
}
