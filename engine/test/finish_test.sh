# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# finish-root.sh: the network left to its adapter, the machine ID cleared, and a read-only root's
# fstab, mount points, and kept paths.

setup_finish() {
  need_yq
  make_team
  make_root
  make_plan
}

run_finish() {
  "$ENGINE/finish-root.sh" --plan "$TMP/plan" --image vision --root "$TMP/root" --keep-out "$TMP/keep" "$@"
}

test_finish_clears_the_machine_id() {
  setup_finish
  run_finish
  [[ ! -s $TMP/root/etc/machine-id ]] || fail "the machine ID isn't cleared"
}

test_finish_makes_the_root_read_only() {
  setup_finish
  run_finish
  local fstab=$TMP/root/etc/fstab
  assert_contains "$fstab" "PARTUUID=0b1c2d3e-02 / ext4 ro,noatime 0 1"
  # The boot partition's line is the base's own, untouched.
  assert_contains "$fstab" "PARTUUID=0b1c2d3e-01 /boot/firmware vfat defaults 0 2"
  assert_contains "$fstab" "LABEL=paddock-data /data ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2"
  assert_contains "$fstab" "/data/var/lib/team /var/lib/team none bind,nofail,x-systemd.requires-mounts-for=/data 0 0"
  assert_contains "$fstab" "/data/var/log/journal /var/log/journal none bind"
  assert_contains "$fstab" "tmpfs /tmp tmpfs mode=1777,nosuid,nodev 0 0"
  assert_contains "$fstab" "tmpfs /var/lib/NetworkManager tmpfs"
  # The base's own /tmp line gives way to Paddock's.
  assert_not_contains "$fstab" "tmpfs /tmp tmpfs defaults,nosuid"
  [[ -d $TMP/root/data && -d $TMP/root/var/lib/systemd ]] || fail "the mount points aren't there"
}

test_finish_moves_the_kept_paths_out() {
  setup_finish
  run_finish
  assert_eq "$(cat "$TMP/keep/var/lib/team/state")" "what the base had"
  assert_mode "$TMP/keep/var/lib/team" 750
  [[ -d $TMP/root/var/lib/team && -z $(ls -A "$TMP/root/var/lib/team") ]] ||
    fail "the mount point isn't left empty"
  [[ -d $TMP/keep/var/log/journal ]] || fail "an empty kept path has no folder on the data partition"
}

test_finish_writes_its_block_after_the_bases_lines() {
  setup_finish
  run_finish
  local fstab=$TMP/root/etc/fstab begin end
  begin=$(grep -n '^# --- Paddock: read-only root' "$fstab" | cut -d: -f1)
  end=$(grep -n '^# --- end Paddock' "$fstab" | cut -d: -f1)
  [[ -n $begin && -n $end ]] || fail "the block has no markers"
  (($(grep -n '/boot/firmware' "$fstab" | cut -d: -f1) < begin)) || fail "the base's lines aren't first"
  (($(grep -n 'LABEL=paddock-data' "$fstab" | cut -d: -f1) == begin + 1)) || fail "/data isn't first in the block"
  (($(wc -l <"$fstab") == end)) || fail "something follows the block"
}

# /var/log is in RAM and /var/log/journal is kept: the journal's line must come after its parent's.
test_finish_mounts_each_path_after_its_parent() {
  setup_finish
  run_finish
  local fstab=$TMP/root/etc/fstab
  (($(grep -n ' /var/log tmpfs' "$fstab" | cut -d: -f1) < $(grep -n ' /var/log/journal none' "$fstab" | cut -d: -f1))) ||
    fail "/var/log/journal is mounted before /var/log"
}

test_finish_rerun_writes_the_same_fstab() {
  setup_finish
  run_finish
  local before
  before=$(sha256sum <"$TMP/root/etc/fstab")
  run_finish
  assert_eq "$(sha256sum <"$TMP/root/etc/fstab")" "$before" "fstab after a rerun"
}

# systemd reads the fstab: every mount a unit, the kept paths after /data, no complaints.
test_finish_writes_an_fstab_systemd_reads() {
  local generator=/usr/lib/systemd/system-generators/systemd-fstab-generator
  [[ -x $generator ]] || skip "needs systemd's fstab generator"
  setup_finish
  run_finish
  mkdir -p "$TMP/units"
  SYSTEMD_FSTAB=$TMP/root/etc/fstab SYSTEMD_PROC_CMDLINE="" "$generator" "$TMP/units" "$TMP/units" "$TMP/units" \
    2>"$TMP/generator.log" || fail "the generator failed: $(cat "$TMP/generator.log")"
  [[ ! -s $TMP/generator.log ]] || fail "the generator complained: $(cat "$TMP/generator.log")"
  local unit
  for unit in data var-lib-team var-log-journal var-log tmp var-tmp var-lib-NetworkManager; do
    assert_file "$TMP/units/$unit.mount"
  done
  assert_contains "$TMP/units/var-lib-team.mount" "RequiresMountsFor=/data"
  assert_contains "$TMP/units/var-log-journal.mount" "RequiresMountsFor=/data"
}

test_finish_refuses_keeping_a_file() {
  setup_finish
  echo 'a file' >"$TMP/root/var/lib/state.db"
  edit_team '.images.vision["read-only"].keep += ["/var/lib/state.db"]'
  make_plan
  assert_fails "keeps /var/lib/state.db, which is a file in the image: keep its folder" run_finish
}

test_finish_refuses_keeping_what_the_base_mounts() {
  setup_finish
  edit_team '.images.vision["read-only"].keep += ["/boot/firmware/overlays"]'
  make_plan
  assert_fails "keeps /boot/firmware/overlays, but the base mounts /boot/firmware there" run_finish
}

test_finish_refuses_two_root_lines() {
  setup_finish
  echo 'LABEL=other / ext4 defaults 0 1' >>"$TMP/root/etc/fstab"
  assert_fails "has 2 lines for the root (/)" run_finish
}

test_finish_reads_a_root_line_of_three_fields() {
  setup_finish
  sed -i 's|^PARTUUID=0b1c2d3e-02 .*|PARTUUID=0b1c2d3e-02 / ext4|' "$TMP/root/etc/fstab"
  run_finish
  assert_contains "$TMP/root/etc/fstab" "PARTUUID=0b1c2d3e-02 / ext4 ro,noatime 0 1"
}

test_finish_leaves_a_writable_root_alone() {
  setup_finish
  edit_team 'del(.images.vision["read-only"])'
  make_plan
  local before
  before=$(cat "$TMP/root/etc/fstab")
  "$ENGINE/finish-root.sh" --plan "$TMP/plan" --image vision --root "$TMP/root"
  assert_eq "$(cat "$TMP/root/etc/fstab")" "$before" "fstab"
}

test_finish_refuses_a_network_left_to_others() {
  setup_finish
  mkdir -p "$TMP/root/etc/netplan"
  printf 'network:\n  ethernets:\n    all:\n      dhcp4: yes\n' >"$TMP/root/etc/netplan/10-dhcp.yaml"
  assert_fails "vision's steps leave the network to more than its network adapter (networkmanager)" run_finish
}

test_finish_refuses_a_base_still_without_its_network_adapters_program() {
  setup_finish
  rm "$TMP/root/usr/sbin/NetworkManager"
  assert_fails "no NetworkManager" run_finish
}

test_finish_needs_a_root_line_in_fstab_or_a_root_id() {
  setup_finish
  sed -i '/ \/ ext4/d' "$TMP/root/etc/fstab"
  assert_fails "has no line for the root (/), and no --root-id" run_finish
}

test_finish_adds_the_roots_line_by_its_id_when_the_base_has_none() {
  setup_finish
  sed -i '/ \/ ext4/d' "$TMP/root/etc/fstab"
  run_finish --root-id UUID=0b1c2d3e-0000-4000-8000-000000000000
  assert_contains "$TMP/root/etc/fstab" "UUID=0b1c2d3e-0000-4000-8000-000000000000 / ext4 ro,noatime 0 1"
  assert_eq "$(grep -c ' / ext4 ' "$TMP/root/etc/fstab")" 1 "root lines"
}

test_finish_keeps_the_bases_root_line_over_the_id() {
  setup_finish
  run_finish --root-id UUID=feedface-0000-4000-8000-000000000000
  assert_not_contains "$TMP/root/etc/fstab" "UUID=feedface"
}

test_finish_writes_an_fstab_for_a_base_without_one() {
  setup_finish
  rm "$TMP/root/etc/fstab"
  run_finish --root-id LABEL=rootfs
  assert_contains "$TMP/root/etc/fstab" "LABEL=rootfs / ext4 ro,noatime 0 1"
  assert_contains "$TMP/root/etc/fstab" "LABEL=paddock-data /data"
}
