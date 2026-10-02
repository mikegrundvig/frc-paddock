# shellcheck shell=bash
# notice.sh: the license notice a release carries, naming the exact software and its source.

test_notice_names_photonvision_its_source_and_each_base_image() {
  need_yq
  "$RECIPE/notice.sh" --boards "orangepi-5 orangepi-5-plus" --spotter-lock "$PADDOCK/spotter.lock" \
    >"$TMP/NOTICE.md"
  local version spotter
  version=$(yq -p json -r '.version' "$RECIPE/photonvision.lock")
  spotter=$(yq -p json -r '.version' "$PADDOCK/spotter.lock")
  assert_contains "$TMP/NOTICE.md" "**PhotonVision $version** (GPL-3.0)"
  assert_contains "$TMP/NOTICE.md" "https://github.com/PhotonVision/photonvision/tree/$version"
  assert_contains "$TMP/NOTICE.md" "Orange Pi 5: photonvision_opi5.img.xz"
  assert_contains "$TMP/NOTICE.md" "Orange Pi 5 Plus: photonvision_opi5plus.img.xz"
  assert_contains "$TMP/NOTICE.md" "https://github.com/PhotonVision/photon-image-modifier/tree/v2027.2.3"
  assert_contains "$TMP/NOTICE.md" "https://github.com/mikegrundvig/frc-spotter/tree/v$spotter"
  assert_not_contains "$TMP/NOTICE.md" "Orange Pi 5 Max"
}
