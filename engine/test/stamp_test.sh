# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# stamp.sh: a computer's identity and its image's labels, written into a root.

setup_stamp() {
  need_yq
  make_team
  make_root
  make_plan --release images-2027.1
}

run_stamp() {
  "$ENGINE/stamp.sh" --plan "$TMP/plan" --computer "$1" --root "$TMP/root" --stamp-out "$TMP/$1.stamp.json"
}

test_stamp_writes_the_identity() {
  setup_stamp
  run_stamp vision-front
  local root=$TMP/root
  assert_eq "$(cat "$root/etc/hostname")" vision-front hostname
  # Every computer in the input, by its address.
  assert_contains "$root/etc/hosts" $'10.12.34.11\tvision-front'
  assert_contains "$root/etc/hosts" $'10.12.34.12\tvision-back'
  assert_contains "$root/etc/hosts" $'192.168.1.50\tbench'
  assert_contains "$root/etc/hosts" $'127.0.0.1\tlocalhost'
  [[ $(cat "$root/etc/machine-id") =~ ^[0-9a-f]{32}$ ]] || fail "machine-id isn't 32 hex digits"
}

test_stamp_writes_the_address_through_the_network_adapter() {
  setup_stamp
  run_stamp vision-front
  assert_contains "$TMP/root/etc/NetworkManager/system-connections/paddock.nmconnection" \
    'address1=10.12.34.11/24,10.12.34.4'
}

test_stamp_gives_each_computer_its_own_machine_id_kept_across_releases() {
  setup_stamp
  run_stamp vision-front
  local front
  front=$(cat "$TMP/root/etc/machine-id")
  run_stamp vision-back
  [[ $front != "$(cat "$TMP/root/etc/machine-id")" ]] || fail "two computers share a machine ID"
  make_plan --release images-2027.2
  run_stamp vision-front
  assert_eq "$(cat "$TMP/root/etc/machine-id")" "$front" "the machine ID in the next release"
}

test_stamp_labels_the_image_in_os_release() {
  setup_stamp
  run_stamp vision-front
  # Debian's /etc/os-release links to /usr/lib/os-release, which gets the labels.
  local file=$TMP/root/usr/lib/os-release
  assert_contains "$file" 'PRETTY_NAME="Debian (fixture)"'
  assert_contains "$file" 'IMAGE_ID="vision"'
  assert_contains "$file" 'IMAGE_VERSION="images-2027.1"'
  assert_contains "$file" 'PADDOCK_COMMIT="0123456789abcdef0123456789abcdef01234567"'
  assert_contains "$file" 'PADDOCK_BUILT_AT="2027-01-10T18:30:00Z"'
  [[ -L $TMP/root/etc/os-release ]] || fail "the link is gone"
}

test_stamp_replaces_its_own_labels() {
  setup_stamp
  run_stamp vision-front
  run_stamp vision-front
  assert_eq "$(grep -c '^IMAGE_ID=' "$TMP/root/usr/lib/os-release")" 1 "IMAGE_ID lines"
}

test_stamp_writes_the_same_bytes_twice() {
  setup_stamp
  run_stamp vision-front
  local first
  first=$(tree_digest "$TMP/root")
  run_stamp vision-front
  assert_eq "$(tree_digest "$TMP/root")" "$first" "the root's digest"
}

test_stamp_writes_the_stamp_record() {
  setup_stamp
  run_stamp bench
  local stamp=$TMP/bench.stamp.json
  assert_eq "$(yq -p json -o yaml -r '.hostname' "$stamp")" bench
  assert_eq "$(yq -p json -o yaml -r '.image' "$stamp")" plain
  assert_eq "$(yq -p json -o yaml -r '.address' "$stamp")" 192.168.1.50/24
  assert_eq "$(yq -p json -o yaml -r '.gateway' "$stamp")" ""
  assert_eq "$(yq -p json -o yaml -r '.dns | join(" ")' "$stamp")" "192.168.1.1 1.1.1.1"
  assert_eq "$(yq -p json -o yaml -r '.release' "$stamp")" images-2027.1
  assert_eq "$(yq -p json -o yaml -r '.base.sha256' "$stamp")" "$SHA_B"
  assert_eq "$(yq -p json -o yaml -r '.packages | length' "$stamp")" 0
  assert_eq "$(yq -p json -o yaml -r '.downloads | length' "$stamp")" 0
  run_stamp vision-front
  stamp=$TMP/vision-front.stamp.json
  assert_eq "$(yq -p json -o yaml -r '.packages[0].url' "$stamp")" \
    https://example.org/releases/example-tool_1.0.0_arm64.deb
  assert_eq "$(yq -p json -o yaml -r '.downloads[0].url' "$stamp")" https://example.org/releases/model.bin
  assert_eq "$(yq -p json -o yaml -r '.downloads[0].sha256' "$stamp")" "$SHA_2"
  assert_eq "$(yq -p json -o yaml -r '.downloads[0].to' "$stamp")" /opt/team/model.bin
}

test_stamp_refuses_a_computer_not_in_the_plan() {
  setup_stamp
  assert_fails "no computer named 'vision-side'" run_stamp vision-side
}

test_stamp_needs_an_os_release_to_label() {
  setup_stamp
  rm "$TMP/root/etc/os-release" "$TMP/root/usr/lib/os-release"
  assert_fails "no /etc/os-release to label" run_stamp vision-front
}

# A link in the image would resolve on the build machine: stamping writes through none.
test_stamp_refuses_to_write_through_a_link() {
  setup_stamp
  mkdir -p "$TMP/elsewhere"
  ln -s "$TMP/elsewhere" "$TMP/root/etc/NetworkManager"
  assert_fails "goes through a link (/etc/NetworkManager)" run_stamp vision-front
  [[ -z $(ls -A "$TMP/elsewhere") ]] || fail "stamping wrote outside the image"
  rm "$TMP/root/etc/NetworkManager"
  ln -sfn "$TMP/elsewhere/hostname" "$TMP/root/etc/hostname"
  assert_fails "goes through a link (/etc/hostname)" run_stamp vision-front
  assert_no_file "$TMP/elsewhere/hostname"
}

# An absolute link, as some bases have it, is followed inside the image, not on this machine.
test_stamp_follows_an_absolute_os_release_link_inside_the_image() {
  setup_stamp
  ln -sfn /usr/lib/os-release "$TMP/root/etc/os-release"
  run_stamp vision-front
  assert_contains "$TMP/root/usr/lib/os-release" 'IMAGE_ID="vision"'
  assert_eq "$(readlink "$TMP/root/etc/os-release")" /usr/lib/os-release "the link"
}

# Each computer gets its own files, over the image's, and its record lists them.
test_stamp_writes_each_computers_own_files() {
  setup_stamp
  mkdir -p "$TMP/team/computers" "$TMP/root/etc/team"
  echo 'fx: 600.0' >"$TMP/team/computers/front.yaml"
  echo 'the image default' >"$TMP/root/etc/team/camera.yaml"
  edit_team '.computers[0].files = [{"file": "computers/front.yaml", "to": "/etc/team/camera.yaml", "mode": "0600"}]'
  make_plan --release images-2027.1
  run_stamp vision-front
  assert_eq "$(cat "$TMP/root/etc/team/camera.yaml")" 'fx: 600.0'
  assert_mode "$TMP/root/etc/team/camera.yaml" 600
  assert_eq "$(yq -p json -o yaml -r '.files[0].to' "$TMP/vision-front.stamp.json")" /etc/team/camera.yaml
  assert_eq "$(yq -p json -o yaml -r '.files[0].sha256' "$TMP/vision-front.stamp.json")" \
    "$(sha256sum <"$TMP/team/computers/front.yaml" | cut -c1-64)"
  run_stamp vision-back
  assert_eq "$(yq -p json -o yaml -r '.files | length' "$TMP/vision-back.stamp.json")" 0
}

test_stamp_refuses_a_computers_file_through_a_link() {
  setup_stamp
  mkdir -p "$TMP/team/computers" "$TMP/elsewhere"
  echo 'fx: 600.0' >"$TMP/team/computers/front.yaml"
  ln -s "$TMP/elsewhere" "$TMP/root/etc/team"
  edit_team '.computers[0].files = [{"file": "computers/front.yaml", "to": "/etc/team/camera.yaml"}]'
  make_plan --release images-2027.1
  assert_fails "goes through a link (/etc/team)" run_stamp vision-front
  [[ -z $(ls -A "$TMP/elsewhere") ]] || fail "stamping wrote outside the image"
}
