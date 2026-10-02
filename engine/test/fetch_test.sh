# shellcheck shell=bash
# fetch.sh: each input downloaded and checked against its lock, and refused when it isn't the lock's.
# A stand-in curl serves local files in place of the releases, the locks pinned to them.

# A recipe copy whose lock points at local files, and a curl that copies them.
setup_fetch() {
  need python3 sha256sum
  make_paddock_copy
  mkdir -p "$TMP/served" "$TMP/bin"
  echo 'base image' >"$TMP/served/photonvision_opi5.img.xz"
  echo 'the jar' >"$TMP/served/photonvision.jar"
  echo 'the agent' >"$TMP/served/frc-coprocessor-agent_0.1.0_arm64.deb"
  local lock=$TMP/paddock/recipes/photonvision-orangepi/photonvision.lock
  python3 - "$lock" "$TMP/paddock/spotter.lock" "$TMP/served" <<'PY'
import hashlib, json, sys
lock, spotter, served = sys.argv[1], sys.argv[2], sys.argv[3]
def pin(name):
    data = open(f"{served}/{name}", "rb").read()
    return {"url": f"https://example.org/{name}", "sha256": hashlib.sha256(data).hexdigest()}
l = json.load(open(lock))
l["jar"] = pin("photonvision.jar")
l["images"]["orangepi-5"] = pin("photonvision_opi5.img.xz")
json.dump(l, open(lock, "w"))
s = json.load(open(spotter))
s["debs"]["arm64"] = pin("frc-coprocessor-agent_0.1.0_arm64.deb")
json.dump(s, open(spotter, "w"))
PY
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
    --spotter-lock "$TMP/paddock/spotter.lock" --out "$TMP/out" "$@"
}

test_fetch_downloads_every_input_checked() {
  setup_fetch
  run_fetch
  assert_eq "$(cat "$TMP/out/base.img.xz")" "base image"
  assert_eq "$(cat "$TMP/out/inputs/photonvision.jar")" "the jar"
  assert_eq "$(cat "$TMP/out/inputs/frc-coprocessor-agent.deb")" "the agent"
  # A second run finds them already here, checked.
  rm "$TMP/served/photonvision.jar"
  run_fetch 2>"$TMP/second.log"
  assert_contains "$TMP/second.log" "photonvision.jar: already here, checked"
}

test_fetch_refuses_a_download_that_isnt_the_locks() {
  setup_fetch
  echo 'another jar' >"$TMP/served/photonvision.jar"
  assert_fails "photonvision.jar isn't the lock's" run_fetch
  assert_no_file "$TMP/out/inputs/photonvision.jar"
}

test_fetch_says_where_spotters_agent_must_come_from() {
  setup_fetch
  rm "$TMP/served/frc-coprocessor-agent_0.1.0_arm64.deb"
  assert_fails "Spotter's release must be public" run_fetch --no-image
}
