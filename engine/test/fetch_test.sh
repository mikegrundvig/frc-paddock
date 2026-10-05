# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# fetch.sh: an image's base and packages downloaded and checked against their SHA-256, and refused
# when they aren't the ones given. A stand-in curl serves local files in place of the internet.

# A team whose image's base and two packages are local files, pinned to them, and a curl that
# copies them.
setup_fetch() {
  need_yq
  need sha256sum
  make_team
  mkdir -p "$TMP/served" "$TMP/bin"
  echo 'base image' >"$TMP/served/base-arm64.img.xz"
  echo 'a tool' >"$TMP/served/example-tool_1.0.0_arm64.deb"
  echo 'another' >"$TMP/served/another_2.0_all.deb"
  echo 'a model' >"$TMP/served/model.bin"
  S=$(sha256sum <"$TMP/served/model.bin" | cut -c1-64) edit_team '.images.vision.steps[4].sha256 = strenv(S)'
  S=$(sha256sum <"$TMP/served/base-arm64.img.xz" | cut -c1-64) edit_team '.images.vision.from.sha256 = strenv(S)'
  S=$(sha256sum <"$TMP/served/example-tool_1.0.0_arm64.deb" | cut -c1-64) edit_team '.images.vision.steps[1].sha256 = strenv(S)'
  S=$(sha256sum <"$TMP/served/another_2.0_all.deb" | cut -c1-64) \
    edit_team '.images.vision.steps += [{"package": "https://example.org/releases/another_2.0_all.deb", "sha256": strenv(S)}]'
  # curl --output FILE URL: copies the served file of the URL's name, or fails as a 404 would.
  cat >"$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while ((\$#)); do
  case \$1 in
    --output) out=\$2; shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
echo "\$url" >>"$TMP/curl.log"
cp "$TMP/served/\${url##*/}" "\$out" 2>/dev/null || { echo "curl: (22) 404" >&2; exit 22; }
EOF
  chmod +x "$TMP/bin/curl"
  make_plan
}

run_fetch() {
  PATH=$TMP/bin:$PATH "$ENGINE/fetch.sh" --plan "$TMP/plan" --image vision --out "$TMP/inputs"
}

test_fetch_downloads_the_base_and_the_packages_in_order() {
  setup_fetch
  run_fetch
  assert_eq "$(cat "$TMP/inputs/base.img.xz")" "base image"
  assert_eq "$(cat "$TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb")" "a tool"
  assert_eq "$(cat "$TMP/inputs/packages/01-another_2.0_all.deb")" "another"
  assert_eq "$(cat "$TMP/inputs/downloads/00-model.bin")" "a model"
}

test_fetch_refuses_a_download_that_isnt_the_one_given() {
  setup_fetch
  echo 'another model' >"$TMP/served/model.bin"
  assert_fails "model.bin isn't the one paddock.yaml gives" run_fetch
  assert_no_file "$TMP/inputs/downloads/00-model.bin"
}

test_fetch_refuses_what_isnt_the_one_given() {
  setup_fetch
  echo 'something else' >"$TMP/served/example-tool_1.0.0_arm64.deb"
  assert_fails "example-tool_1.0.0_arm64.deb isn't the one paddock.yaml gives" run_fetch
  assert_no_file "$TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb"
  assert_no_file "$TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb.part"
}

test_fetch_says_when_a_download_fails() {
  setup_fetch
  rm "$TMP/served/base-arm64.img.xz"
  assert_fails "vision's base couldn't be downloaded" run_fetch
}

test_fetch_keeps_what_it_already_has() {
  setup_fetch
  run_fetch
  : >"$TMP/curl.log"
  run_fetch
  [[ ! -s $TMP/curl.log ]] || fail "it downloaded again: $(cat "$TMP/curl.log")"
}

test_fetch_removes_packages_the_plan_no_longer_has() {
  setup_fetch
  run_fetch
  edit_team 'del(.images.vision.steps[5]) | del(.images.vision.steps[4])'
  make_plan
  run_fetch
  assert_no_file "$TMP/inputs/packages/01-another_2.0_all.deb"
  assert_no_file "$TMP/inputs/downloads/00-model.bin"
}

test_fetch_names_the_base_by_its_format() {
  setup_fetch
  echo 'plain image' >"$TMP/served/plain-amd64.img"
  S=$(sha256sum <"$TMP/served/plain-amd64.img" | cut -c1-64) edit_team '.images.plain.from.sha256 = strenv(S)'
  make_plan
  PATH=$TMP/bin:$PATH "$ENGINE/fetch.sh" --plan "$TMP/plan" --image plain --out "$TMP/plain"
  assert_eq "$(cat "$TMP/plain/base.img")" "plain image"
}

test_fetch_replaces_a_file_that_isnt_right() {
  setup_fetch
  mkdir -p "$TMP/inputs"
  echo 'a different base' >"$TMP/inputs/base.img.xz"
  echo 'a stale part' >"$TMP/inputs/base.img.xz.part"
  run_fetch
  assert_eq "$(cat "$TMP/inputs/base.img.xz")" "base image"
  assert_no_file "$TMP/inputs/base.img.xz.part"
}
