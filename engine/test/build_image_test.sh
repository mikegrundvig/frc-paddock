# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# build-image.sh's, stamp-image.sh's and local-build.sh's checks before they mount anything. The
# mounting needs root and loop devices: the harness's BuiltImageContainerTest and CI's examples.

setup_build() {
  need_yq
  make_team
  make_plan
  mkdir -p "$TMP/inputs/packages"
}

test_build_image_refuses_what_it_cant_build() {
  setup_build
  assert_fails "--plan, --image, and --out are required" "$ENGINE/build-image.sh" --plan "$TMP/plan"
  assert_fails "--config-dir must be paddock.yaml's folder" "$ENGINE/build-image.sh" --plan "$TMP/plan" \
    --image vision --config-dir "$TMP/none" --inputs "$TMP/inputs" --out "$TMP/vision.img"
  assert_fails "--inputs must be what fetch.sh downloaded" "$ENGINE/build-image.sh" --plan "$TMP/plan" \
    --image vision --config-dir "$TMP/team" --inputs "$TMP/none" --out "$TMP/vision.img"
  assert_fails "no image named 'side'" "$ENGINE/build-image.sh" --plan "$TMP/plan" \
    --image side --config-dir "$TMP/team" --inputs "$TMP/inputs" --out "$TMP/vision.img"
  if ((EUID != 0)); then
    assert_fails "needs root" "$ENGINE/build-image.sh" --plan "$TMP/plan" --image vision \
      --config-dir "$TMP/team" --inputs "$TMP/inputs" --out "$TMP/vision.img"
  fi
}

test_stamp_image_refuses_what_it_cant_stamp() {
  setup_build
  assert_fails "no image file" "$ENGINE/stamp-image.sh" --plan "$TMP/plan" --computer vision-front "$TMP/none.img"
  : >"$TMP/vision.img"
  if ((EUID != 0)); then
    assert_fails "needs root" "$ENGINE/stamp-image.sh" --plan "$TMP/plan" --computer vision-front "$TMP/vision.img"
  fi
}

test_local_build_refuses_without_root_or_a_team() {
  setup_build
  if ((EUID != 0)); then
    assert_fails "needs root" "$ENGINE/local-build.sh" --team "$TMP/team"
  fi
  assert_fails "--team is required" "$ENGINE/local-build.sh"
}

# The workflow runs the engine's scripts directly: each needs its executable bit (in Git, too).
test_engine_scripts_are_executable() {
  local script
  for script in "$ENGINE"/*.sh "$ENGINE"/ci/*.sh; do
    [[ $(head -c 2 "$script") != '#!' || -x $script ]] || fail "${script#"$PADDOCK"/} isn't executable"
  done
}

test_attach_image_says_why_it_cant() {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "losetup: failed to set up loop device" >&2\nexit 1\n' >"$TMP/bin/losetup"
  chmod +x "$TMP/bin/losetup"
  # shellcheck disable=SC2016 # expanded by the inner bash
  PATH=$TMP/bin:$PATH assert_fails "couldn't attach disk.img to a loop device" bash -c \
    'set -e; . "$1/lib/common.sh"; loop=$(attach_image disk.img); echo "attached: $loop"' _ "$ENGINE"
}
