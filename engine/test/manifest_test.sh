# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# manifest.sh: a release's SHA256SUMS and manifest.json, from its images and their stamps.

setup_manifest() {
  need_yq
  need sha256sum
  make_team
  make_root
  make_plan --release images-2027.1
  mkdir -p "$TMP/release"
  local name
  for name in vision-front bench; do
    "$ENGINE/stamp.sh" --plan "$TMP/plan" --computer "$name" --root "$TMP/root" \
      --stamp-out "$TMP/release/$name-images-2027.1.stamp.json"
    echo "$name's image" >"$TMP/release/$name-images-2027.1.img.xz"
  done
}

test_manifest_lists_every_computer() {
  setup_manifest
  "$ENGINE/manifest.sh" "$TMP/release"
  local manifest=$TMP/release/manifest.json
  assert_eq "$(yq -p json -o yaml -r '.schema' "$manifest")" 1
  assert_eq "$(yq -p json -o yaml -r '.release' "$manifest")" images-2027.1
  assert_eq "$(yq -p json -o yaml -r '.commit' "$manifest")" 0123456789abcdef0123456789abcdef01234567
  assert_eq "$(yq -p json -o yaml -r '[.computers[].hostname] | join(" ")' "$manifest")" "bench vision-front"
  assert_eq "$(yq -p json -o yaml -r '.computers[1].file' "$manifest")" vision-front-images-2027.1.img.xz
  assert_eq "$(yq -p json -o yaml -r '.computers[1].fileSha256' "$manifest")" \
    "$(sha256sum <"$TMP/release/vision-front-images-2027.1.img.xz" | cut -c1-64)"
  assert_eq "$(yq -p json -o yaml -r '.computers[1].base.url' "$manifest")" https://example.org/images/base-arm64.img.xz
  assert_eq "$(yq -p json -o yaml -r '.computers[1] | has("release")' "$manifest")" false
}

test_manifest_sums_check_the_files() {
  setup_manifest
  echo 'the team notice' >"$TMP/release/LICENSES.md"
  "$ENGINE/manifest.sh" "$TMP/release" --notice LICENSES.md
  assert_eq "$(wc -l <"$TMP/release/SHA256SUMS")" 3 "lines"
  assert_contains "$TMP/release/SHA256SUMS" "  LICENSES.md"
  (cd "$TMP/release" && sha256sum --check --strict --quiet SHA256SUMS) || fail "SHA256SUMS doesn't check"
}

test_manifest_refuses_an_image_without_its_stamp() {
  setup_manifest
  echo 'stray' >"$TMP/release/stray-images-2027.1.img.xz"
  assert_fails "stray-images-2027.1.img.xz has no stamp" "$ENGINE/manifest.sh" "$TMP/release"
}

test_manifest_refuses_images_of_two_releases() {
  setup_manifest
  make_plan --release images-2027.2
  "$ENGINE/stamp.sh" --plan "$TMP/plan" --computer vision-back --root "$TMP/root" \
    --stamp-out "$TMP/release/vision-back-images-2027.2.stamp.json"
  echo 'back' >"$TMP/release/vision-back-images-2027.2.img.xz"
  assert_fails "the images aren't all of one release" "$ENGINE/manifest.sh" "$TMP/release"
}
