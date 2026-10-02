# shellcheck shell=bash
# notice.sh: the license notice a release carries, naming the exact software and its source.

test_notice_names_photonvision_its_source_and_each_base_image() {
  need_yq
  printf '%064d https://example.org/releases/example-tool_1.0.0_arm64.deb\n' 1 >"$TMP/packages.list"
  "$RECIPE/notice.sh" --boards "orangepi-5 orangepi-5-plus" --packages "$TMP/packages.list" \
    >"$TMP/NOTICE.md"
  local version
  version=$(yq -p json -r '.version' "$RECIPE/photonvision.lock")
  assert_contains "$TMP/NOTICE.md" "**PhotonVision $version** (GPL-3.0)"
  assert_contains "$TMP/NOTICE.md" "https://github.com/PhotonVision/photonvision/tree/$version"
  assert_contains "$TMP/NOTICE.md" "Orange Pi 5: photonvision_opi5.img.xz"
  assert_contains "$TMP/NOTICE.md" "Orange Pi 5 Plus: photonvision_opi5plus.img.xz"
  assert_contains "$TMP/NOTICE.md" "https://github.com/PhotonVision/photon-image-modifier/tree/v2027.2.3"
  assert_contains "$TMP/NOTICE.md" "  - https://example.org/releases/example-tool_1.0.0_arm64.deb"
  assert_not_contains "$TMP/NOTICE.md" "Orange Pi 5 Max"
}

test_notice_without_packages_names_none() {
  need_yq
  : >"$TMP/packages.list"
  "$RECIPE/notice.sh" --boards orangepi-5 --packages "$TMP/packages.list" >"$TMP/NOTICE.md"
  assert_not_contains "$TMP/NOTICE.md" "The packages the team's images get"
  assert_contains "$TMP/NOTICE.md" "nvme-cli"
}
