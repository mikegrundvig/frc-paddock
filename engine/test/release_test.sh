# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# release.sh: a release published at the commit built, never replacing one. A stand-in gh answers
# from files in $TMP/gh and logs what it's asked to do.

COMMIT=0123456789abcdef0123456789abcdef01234567

setup_release() {
  need_yq
  mkdir -p "$TMP/release" "$TMP/gh" "$TMP/bin"
  echo 'an image' >"$TMP/release/vision-front-images-2027.1.img.xz"
  echo 'sums' >"$TMP/release/SHA256SUMS"
  echo 'notice' >"$TMP/release/NOTICE.md"
  cat >"$TMP/release/manifest.json" <<'EOF'
{"schema": 1, "computers": [{"hostname": "vision-front", "address": "10.12.34.11/24", "image": "vision",
  "file": "vision-front-images-2027.1.img.xz"}]}
EOF
  # gh release view NAME: $TMP/gh/release, if it's there. gh api GET: $TMP/gh/ref, $TMP/gh/tag.
  cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$TMP/gh.log"
case "\$1 \$2" in
  "release view") [[ -f $TMP/gh/release ]] && cat "$TMP/gh/release" ;;
  "release create") exit 0 ;;
  "api --method") exit 0 ;;
  "api repos/"*/git/ref/tags/*) [[ -f $TMP/gh/ref ]] && cat "$TMP/gh/ref" ;;
  "api repos/"*/git/tags/*) cat "$TMP/gh/tag" ;;
  *) echo "gh stand-in: unexpected \$*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
}

run_release() {
  PATH=$TMP/bin:$PATH "$ENGINE/release.sh" --dir "$TMP/release" --release images-2027.1 --commit "$COMMIT" \
    --repository team/robot-images "$@"
}

test_release_makes_the_tag_at_the_commit_then_the_release() {
  setup_release
  run_release --notice NOTICE.md
  assert_contains "$TMP/gh.log" "gh api --method POST repos/team/robot-images/git/refs -f ref=refs/tags/images-2027.1 -f sha=$COMMIT"
  assert_contains "$TMP/gh.log" "gh release create images-2027.1 --repo team/robot-images --verify-tag"
  assert_contains "$TMP/gh.log" "vision-front-images-2027.1.img.xz $TMP/release/SHA256SUMS $TMP/release/manifest.json $TMP/release/NOTICE.md"
}

test_release_takes_a_tag_already_at_the_commit() {
  setup_release
  printf '{"object": {"type": "commit", "sha": "%s"}}' "$COMMIT" >"$TMP/gh/ref"
  run_release
  assert_not_contains "$TMP/gh.log" "--method POST"
  assert_contains "$TMP/gh.log" "gh release create images-2027.1"
}

test_release_follows_an_annotated_tag_to_its_commit() {
  setup_release
  printf '{"object": {"type": "tag", "sha": "%s"}}' "$SHA_A" >"$TMP/gh/ref"
  printf '{"object": {"type": "commit", "sha": "%s"}}' "$COMMIT" >"$TMP/gh/tag"
  run_release
  assert_contains "$TMP/gh.log" "gh api repos/team/robot-images/git/tags/$SHA_A"
  assert_contains "$TMP/gh.log" "gh release create images-2027.1"
}

test_release_refuses_a_tag_at_another_commit() {
  setup_release
  printf '{"object": {"type": "commit", "sha": "%s"}}' "${SHA_B:0:40}" >"$TMP/gh/ref"
  assert_fails "tag images-2027.1 points at bbbbbbbbbbbb, but these images were built from 0123456789ab" run_release
  assert_not_contains "$TMP/gh.log" "release create"
}

test_release_refuses_a_name_unlike_the_tag_that_started_it() {
  setup_release
  assert_fails "tag images-2027.2 started this run, but the release is named images-2027.1" \
    run_release --tag-name images-2027.2
}

test_release_never_replaces_a_release() {
  setup_release
  echo '{"isDraft": false}' >"$TMP/gh/release"
  assert_fails "release images-2027.1 already exists, and a release is never replaced" run_release
  echo '{"isDraft": true}' >"$TMP/gh/release"
  assert_fails "a draft release images-2027.1 is left from a run that stopped" run_release
  assert_not_contains "$TMP/gh.log" "release create"
}
