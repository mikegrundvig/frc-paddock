# shellcheck shell=bash
# fetch.sh: each input downloaded and checked against its lock, each team's package against its
# sha256, and refused when it isn't the one given. A stand-in curl serves local files in place of
# the releases, the lock and the list pinned to them.

# A recipe copy whose lock points at local files, a package list of two, and a curl that copies
# them.
setup_fetch() {
  need python3 sha256sum
  make_paddock_copy
  mkdir -p "$TMP/served" "$TMP/bin"
  echo 'base image' >"$TMP/served/photonvision_opi5.img.xz"
  echo 'the jar' >"$TMP/served/photonvision.jar"
  echo 'a tool' >"$TMP/served/example-tool_1.0.0_arm64.deb"
  echo 'another' >"$TMP/served/another_2.0_all.deb"
  local lock=$TMP/paddock/recipes/photonvision-orangepi/photonvision.lock
  python3 - "$lock" "$TMP/served" <<'PY'
import hashlib, json, sys
lock, served = sys.argv[1], sys.argv[2]
def pin(name):
    data = open(f"{served}/{name}", "rb").read()
    return {"url": f"https://example.org/{name}", "sha256": hashlib.sha256(data).hexdigest()}
l = json.load(open(lock))
l["jar"] = pin("photonvision.jar")
l["images"]["orangepi-5"] = pin("photonvision_opi5.img.xz")
json.dump(l, open(lock, "w"))
PY
  local name
  for name in example-tool_1.0.0_arm64.deb another_2.0_all.deb; do
    printf '%s https://example.org/releases/%s\n' "$(sha256sum <"$TMP/served/$name" | cut -c1-64)" "$name"
  done >"$TMP/packages.list"
  # curl --output FILE URL: copies the served file of the URL's name, or fails as a 404 would.
  cat >"$TMP/bin/curl" <<EOF2
#!/usr/bin/env bash
out="" url=""
while ((\$#)); do
  case \$1 in
    --output) out=\$2; shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
cp "$TMP/served/\${url##*/}" "\$out" 2>/dev/null || { echo "curl: (22) 404" >&2; exit 22; }
EOF2
  chmod +x "$TMP/bin/curl"
}

run_fetch() {
  PATH=$TMP/bin:$PATH "$TMP/paddock/engine/fetch.sh" \
    --recipe-dir "$TMP/paddock/recipes/photonvision-orangepi" --board orangepi-5 \
    --packages "$TMP/packages.list" --out "$TMP/out" "$@"
}

test_fetch_downloads_every_input_checked() {
  setup_fetch
  run_fetch
  assert_eq "$(cat "$TMP/out/base.img.xz")" "base image"
  assert_eq "$(cat "$TMP/out/inputs/photonvision.jar")" "the jar"
  # The packages, numbered in the list's order.
  assert_eq "$(ls "$TMP/out/packages" | paste -sd ' ')" "00-example-tool_1.0.0_arm64.deb 01-another_2.0_all.deb"
  assert_eq "$(cat "$TMP/out/packages/00-example-tool_1.0.0_arm64.deb")" "a tool"
  # A second run finds them already here, checked.
  rm "$TMP/served/photonvision.jar" "$TMP/served/example-tool_1.0.0_arm64.deb"
  run_fetch 2>"$TMP/second.log"
  assert_contains "$TMP/second.log" "photonvision.jar: already here, checked"
  assert_contains "$TMP/second.log" "example-tool_1.0.0_arm64.deb: already here, checked"
}

test_fetch_keeps_only_the_lists_packages() {
  setup_fetch
  run_fetch --no-image
  sed -i 1d "$TMP/packages.list"
  run_fetch --no-image
  assert_eq "$(ls "$TMP/out/packages")" "00-another_2.0_all.deb"
  : >"$TMP/packages.list"
  run_fetch --no-image
  assert_eq "$(ls "$TMP/out/packages" | wc -l)" 0 "packages left"
}

test_fetch_refuses_a_download_that_isnt_the_locks() {
  setup_fetch
  echo 'another jar' >"$TMP/served/photonvision.jar"
  assert_fails "photonvision.jar isn't the one pinned" run_fetch
  assert_no_file "$TMP/out/inputs/photonvision.jar"
}

test_fetch_refuses_a_package_that_isnt_the_one_listed() {
  setup_fetch
  echo 'a changed tool' >"$TMP/served/example-tool_1.0.0_arm64.deb"
  assert_fails "example-tool_1.0.0_arm64.deb isn't the one pinned" run_fetch --no-image
  assert_no_file "$TMP/out/packages/00-example-tool_1.0.0_arm64.deb"
}

test_fetch_says_where_a_package_must_come_from() {
  setup_fetch
  rm "$TMP/served/another_2.0_all.deb"
  assert_fails "its release must be public" run_fetch --no-image
}
