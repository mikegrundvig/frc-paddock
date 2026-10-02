# shellcheck shell=bash
# install-software.sh, offline on a directory tree: the team's packages unpacked and its files
# copied in with their modes. (Installing with apt runs only in the image's chroot, in CI.)

run_install() {
  "$ENGINE/install-software.sh" --packages "$TMP/packages" --files "$TMP/software/files" \
    --root "$TMP/root" --offline
}

setup_install() {
  need dpkg-deb
  mkdir -p "$TMP/root"
  make_software
}

test_install_unpacks_the_packages_and_copies_the_files() {
  setup_install
  run_install
  assert_mode "$TMP/root/usr/bin/example-tool" 755
  assert_file "$TMP/root/usr/lib/systemd/system/example-tool.service"
  assert_eq "$(cat "$TMP/root/etc/example/packs/example.yaml")" "checks: [example]"
  assert_mode "$TMP/root/etc/example/packs/example.yaml" 600
  assert_mode "$TMP/root/opt/team/check.sh" 755
}

test_install_replaces_what_was_there_and_can_be_rerun() {
  setup_install
  mkdir -p "$TMP/root/etc/example/packs"
  echo 'old' >"$TMP/root/etc/example/packs/example.yaml"
  chmod 0666 "$TMP/root/etc/example/packs/example.yaml"
  run_install
  assert_mode "$TMP/root/etc/example/packs/example.yaml" 600
  local first
  first=$(tree_digest "$TMP/root")
  run_install
  assert_eq "$(tree_digest "$TMP/root")" "$first" "the tree after a second run"
}

test_install_takes_no_packages_and_no_files() {
  setup_install
  rm "$TMP/packages"/*.deb
  : >"$TMP/software/files/files.list"
  run_install 2>"$TMP/log"
  assert_contains "$TMP/log" "installed 0 package(s) and 0 file(s)"
}

test_install_refuses_a_files_list_it_cant_trust() {
  setup_install
  echo '0644 etc/relative.yaml 0' >"$TMP/software/files/files.list"
  assert_fails "isn't a mode, a destination, and a file" run_install
  echo '0644 /etc/../escape.yaml 0' >"$TMP/software/files/files.list"
  assert_fails "isn't a mode, a destination, and a file" run_install
  echo 'rw /etc/x.yaml 0' >"$TMP/software/files/files.list"
  assert_fails "isn't a mode, a destination, and a file" run_install
  echo '0644 /etc/x.yaml 7' >"$TMP/software/files/files.list"
  assert_fails "names 7, which isn't there" run_install
  rm "$TMP/software/files/files.list"
  assert_fails "must be a folder with its files.list" run_install
}
