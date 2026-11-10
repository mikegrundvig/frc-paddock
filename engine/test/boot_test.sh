# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# boot-image.sh's checks before it mounts or boots anything. The boot itself needs root, loop
# devices and systemd-nspawn on a machine of the image's architecture: CI's examples run it.

setup_boot() {
  need_yq
  make_team
  edit_team '.images.vision.boot.check = "setup/check.sh"'
  make_plan
  : >"$TMP/vision.img"
}

boot() {
  "$ENGINE/boot-image.sh" --plan "$TMP/plan" --image vision --config-dir "$TMP/team" "$TMP/vision.img"
}
boot_as_given=$(declare -f boot)

test_boot_image_leaves_an_image_without_a_boot_check_unbooted() {
  need_yq
  make_team
  make_plan
  : >"$TMP/vision.img"
  local output
  output=$(boot 2>&1) || fail "it failed: $output"
  [[ $output == *"vision has no boot check (boot.check in paddock.yaml), so it isn't booted"* ]] ||
    fail "it didn't say so: $output"
}

# Each row: what's wrong, what makes it so, and what boot-image.sh must say. Each starts from a
# plan whose vision image has a boot check.
test_boot_image_refuses_what_it_cant_boot() {
  local base=$TMP rows what change text n=0
  rows=$(
    cat <<'ROWS'
no plan given	boot() { "$ENGINE/boot-image.sh" --image vision --config-dir "$TMP/team" "$TMP/vision.img"; }	--plan, --image, and --config-dir are required
no image file	rm "$TMP/vision.img"	no image file at
an image the plan hasn't	boot() { "$ENGINE/boot-image.sh" --plan "$TMP/plan" --image side --config-dir "$TMP/team" "$TMP/vision.img"; }	no image named 'side'
the check isn't in the folder given	rm "$TMP/team/setup/check.sh"	no boot check at
ROWS
  )
  while IFS=$'\t' read -r what change text; do
    TMP=$base/$((++n))
    mkdir -p "$TMP"
    setup_boot
    # A row may call boot-image.sh otherwise; the next starts from the usual call.
    eval "$boot_as_given"
    eval "$change"
    (assert_fails "$text" boot) || fail "row: $what"
  done <<<"$rows"
  if ((EUID != 0)); then
    TMP=$base/root
    mkdir -p "$TMP"
    setup_boot
    assert_fails "needs root" boot
  fi
}
