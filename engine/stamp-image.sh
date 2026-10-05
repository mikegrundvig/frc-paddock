#!/usr/bin/env bash
# stamp-image.sh: stamps a computer's copy of its image (stamp.sh into its mounted root), then checks
# the root's filesystem.
#
#   sudo stamp-image.sh --plan DIR --computer HOSTNAME IMAGE.img [--stamp-out FILE]
#
# Needs root and loop devices. The tests run stamp.sh itself.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" computer="" file="" stamp_args=()
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --computer) need_value "$@"; computer=$2; shift 2 ;;
    --stamp-out) need_value "$@"; stamp_args+=(--stamp-out "$2"); shift 2 ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1" ;;
    *) file=$1; shift ;;
  esac
done
[[ -n $plan && -n $computer ]] || die "--plan and --computer are required"
[[ -f $file ]] || die "no image file at '$file'"
((EUID == 0)) || die "needs root, to mount the image"
load_computer "$plan" "$computer"
load_image "$plan" "$COMPUTER_IMAGE"

# The root is the last partition, or the one before the data partition.
root_partition=$(partition_count "$file")
if [[ $READ_ONLY == yes ]]; then
  root_partition=$((root_partition - 1))
fi
((root_partition > 0)) || die "$file has no root partition"

mnt=$(mktemp -d)
loop=""
cleanup() {
  if mountpoint -q "$mnt"; then
    umount "$mnt" 2>/dev/null || umount --lazy "$mnt" || say "couldn't unmount $mnt"
  fi
  if [[ -n $loop ]]; then
    losetup --detach "$loop" || say "couldn't detach $loop"
  fi
  rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

loop=$(attach_image "$file")
root_dev=${loop}p$root_partition
wait_for_device "$root_dev"
mount "$root_dev" "$mnt"
"$here/stamp.sh" --plan "$plan" --computer "$computer" --root "$mnt" "${stamp_args[@]}"
sync
umount "$mnt"
fs_check "$root_dev" || die "$computer's root has errors after stamping"
say "stamped $file"
