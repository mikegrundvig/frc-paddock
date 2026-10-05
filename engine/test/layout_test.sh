# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# layout.sh: the data partition added after an image's root, on the image file itself.

setup_layout() {
  need_yq
  need sfdisk mkfs.ext4 debugfs
  make_team
  make_plan
  mkdir -p "$TMP/keep/var/lib/team"
  echo 'kept' >"$TMP/keep/var/lib/team/state"
}

# An image file like a base, as LABEL (dos or gpt): a 16 MiB boot partition and a root of SECTORS
# (default 32 MiB).
make_disk() {
  local root_size=${2:-65536}
  truncate -s $(((34816 + root_size + 2048) * 512)) "$TMP/disk.img"
  printf 'label: %s\nstart=2048, size=32768, type=%s\nstart=34816, size=%s, type=%s\n' "$1" \
    "$([[ $1 == gpt ]] && echo EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 || echo c)" "$root_size" \
    "$([[ $1 == gpt ]] && echo 0FC63DAF-8483-4772-8E79-3D69D8477DE4 || echo 83)" |
    sfdisk --quiet "$TMP/disk.img"
}

run_layout() {
  "$ENGINE/layout.sh" --plan "$TMP/plan" --image vision --keep "$TMP/keep" "$TMP/disk.img"
}

# The data partition's start and size, in sectors.
data_partition() {
  sfdisk --dump "$TMP/disk.img" | awk -F'[=,]' '/disk.img3/ { gsub(/ /, ""); print $2, $4 }'
}

# The data partition: 64 MiB, aligned, after the root (of ROOT_SECTORS), holding what was kept.
check_layout() {
  local start size
  read -r start size < <(data_partition)
  assert_eq "$size" $((64 * 2048)) "the data partition's size, in sectors"
  ((start % (16 * 2048) == 0)) || fail "the data partition starts at $start, not on 16 MiB"
  ((start >= 34816 + ${1:-65536})) || fail "the data partition overlaps the root"
  dd if="$TMP/disk.img" of="$TMP/data.fs" bs=512 skip="$start" count="$size" status=none
  assert_eq "$(debugfs -R 'cat /var/lib/team/state' "$TMP/data.fs" 2>/dev/null)" kept
  [[ $(debugfs -R 'stats' "$TMP/data.fs" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p') == paddock-data ]] ||
    fail "the data partition isn't labelled paddock-data"
}

test_layout_adds_the_data_partition_dos() {
  setup_layout
  make_disk dos
  run_layout
  check_layout
}

test_layout_adds_the_data_partition_gpt() {
  setup_layout
  make_disk gpt
  run_layout
  check_layout
  sfdisk --verify "$TMP/disk.img" >/dev/null 2>&1 || fail "the GPT doesn't verify"
}

test_layout_leaves_a_laid_out_image_alone() {
  setup_layout
  make_disk dos
  run_layout
  local before
  before=$(sha256sum <"$TMP/disk.img")
  run_layout
  assert_eq "$(sha256sum <"$TMP/disk.img")" "$before" "the image"
}

# A root the data partition's size, with no paddock-data label, is still the root.
test_layout_tells_the_data_partition_by_its_label() {
  setup_layout
  make_disk dos $((64 * 2048))
  run_layout
  check_layout $((64 * 2048))
}

test_layout_refuses_a_full_mbr() {
  setup_layout
  truncate -s 64M "$TMP/disk.img"
  printf 'label: dos\nstart=2048, size=8192\nstart=10240, size=8192\nstart=18432, size=8192\nstart=26624, size=8192\n' |
    sfdisk --quiet "$TMP/disk.img"
  assert_fails "an MBR table has no room for a data partition" run_layout
}

test_layout_refuses_an_image_without_a_read_only_root() {
  setup_layout
  make_disk dos
  assert_fails "has no read-only root" "$ENGINE/layout.sh" --plan "$TMP/plan" --image plain "$TMP/disk.img"
}
