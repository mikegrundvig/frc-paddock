# shellcheck shell=bash
# chroot-provision.sh's checks before it mounts anything (the chroot itself needs root and loop
# devices: the image workflow runs it, on the recipe's runner).

test_chroot_provision_refuses_what_it_cant_run() {
  : >"$TMP/base.img"
  mkdir -p "$TMP/build"
  local ok=(--image "$TMP/base.img" --root-partition 1 --grow-mb 1024 --bind "$TMP/build")
  assert_fails "no command to run" "$ENGINE/chroot-provision.sh" "${ok[@]}"
  assert_fails "no image file" "$ENGINE/chroot-provision.sh" --image "$TMP/none.img" \
    --root-partition 1 --grow-mb 0 --bind "$TMP/build" -- true
  assert_fails "must be a partition's number" "$ENGINE/chroot-provision.sh" --image "$TMP/base.img" \
    --root-partition x --grow-mb 0 --bind "$TMP/build" -- true
  assert_fails "must be a number of MiB" "$ENGINE/chroot-provision.sh" --image "$TMP/base.img" \
    --root-partition 1 --grow-mb lots --bind "$TMP/build" -- true
  if ((EUID != 0)); then
    assert_fails "needs root" "$ENGINE/chroot-provision.sh" "${ok[@]}" -- true
  fi
}
