# shellcheck shell=bash
# manifest.sh: a release's SHA256SUMS and manifest.json, from its images and stamps.

# An image and stamp per computer, in $TMP/release. Options after the name go to stamp.sh.
release_image() {
  local name=$1 base
  shift
  base="$TMP/release/1234-$name-coprocessors-1"
  mkdir -p "$TMP/release"
  rm -rf "$TMP/out"
  run_stamp "$name" --stamp-out "$base.stamp.json" "$@" 2>/dev/null
  printf 'compressed image of %s\n' "$name" >"$base.img.xz"
}

setup_manifest() {
  need_yq
  need sha256sum
  make_team
  make_settings_tool
}

test_manifest_lists_every_computer_and_its_checksum() {
  setup_manifest
  release_image vision-front
  release_image vision-back
  echo 'the notice' >"$TMP/release/NOTICE.md"
  "$ENGINE/manifest.sh" "$TMP/release"
  (cd "$TMP/release" && sha256sum --quiet -c SHA256SUMS) || fail "SHA256SUMS doesn't check"
  assert_eq "$(wc -l <"$TMP/release/SHA256SUMS")" 3 "lines in SHA256SUMS: the images and the notice"
  local manifest=$TMP/release/manifest.json
  assert_eq "$(yq -r '.team' "$manifest")" 1234
  assert_eq "$(yq -r '.release' "$manifest")" coprocessors-1
  assert_eq "$(yq -r '[.computers[].name] | join(" ")' "$manifest")" "vision-back vision-front"
  assert_eq "$(yq -r '.computers[1].address' "$manifest")" 10.12.34.11
  assert_eq "$(yq -r '.computers[1].labels.photonvisionVersion' "$manifest")" v2027.0.0-alpha-2
  [[ $(yq -r '.computers[1].labels.settingsHash' "$manifest") =~ ^[0-9a-f]{64}$ ]] ||
    fail "no settings hash for vision-front"
  assert_eq "$(yq -r '.computers[1].imageSha256' "$manifest")" \
    "$(sha256sum <"$TMP/release/$(yq -r '.computers[1].image' "$manifest")" | cut -c1-64)"
}

test_manifest_records_the_common_images_checksum() {
  setup_manifest
  release_image vision-front
  release_image vision-back
  printf '%064d\n' 7 >"$TMP/release/1234-vision-front-coprocessors-1.common-sha256"
  "$ENGINE/manifest.sh" "$TMP/release"
  local manifest=$TMP/release/manifest.json
  assert_eq "$(yq -r '.computers[1].commonImageSha256' "$manifest")" "$(printf '%064d' 7)"
  assert_eq "$(yq -r '.computers[0] | has("commonImageSha256")' "$manifest")" false
  assert_eq "$(wc -l <"$TMP/release/SHA256SUMS")" 2 "lines in SHA256SUMS"
}

test_manifest_refuses_images_from_two_releases() {
  setup_manifest
  release_image vision-front
  release_image vision-back --release coprocessors-2
  assert_fails "don't share one version" "$ENGINE/manifest.sh" "$TMP/release"
}

test_manifest_refuses_an_image_without_a_stamp() {
  setup_manifest
  release_image vision-front
  echo 'stray' >"$TMP/release/other.img.xz"
  assert_fails "has no stamp" "$ENGINE/manifest.sh" "$TMP/release"
}
