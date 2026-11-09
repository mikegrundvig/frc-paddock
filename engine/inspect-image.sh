#!/usr/bin/env bash
# inspect-image.sh: checks an image build-image.sh built, before any computer is stamped from it or
# it's released: that it holds what its steps put in it and its configuration passes its init's
# checks (inspect-root.sh), and that its SSH server takes its configuration.
#
#   sudo inspect-image.sh --plan DIR --image NAME IMAGE.img
#
# Attaches the image read-only and mounts its root as its computers see it: its other partitions
# where its fstab says and, on a read-only root, the kept paths bound from the data partition. Then inspect-root.sh, and, if the
# image has /usr/sbin/sshd, `sshd -t` run inside it with a throwaway host key (the image's own may
# be made at first boot). Changes nothing in the image. Needs root, losetup, blkid, mount and chroot.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" file=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1" ;;
    *) file=$1; shift ;;
  esac
done
[[ -n $plan && -n $image ]] || die "--plan and --image are required"
[[ -f $file ]] || die "no image file at '$file'"
load_image "$plan" "$image"
((EUID == 0)) || die "needs root: it mounts the image"
for tool in losetup blkid mount chroot; do
  command -v "$tool" >/dev/null || die "needs $tool"
done

root_partition=$(partition_count "$file")
if [[ $READ_ONLY == yes ]]; then
  root_partition=$((root_partition - 1))
fi
((root_partition > 0)) || die "$file has no root partition"

mnt="" loop=""
cleanup() {
  if [[ -n $mnt ]]; then
    if mountpoint -q "$mnt"; then
      umount --recursive "$mnt" 2>/dev/null || umount --recursive --lazy "$mnt" || say "couldn't unmount $mnt"
    fi
    rmdir "$mnt" 2>/dev/null || true
  fi
  if [[ -n $loop ]]; then
    losetup --detach "$loop" || say "couldn't detach $loop"
  fi
}
trap cleanup EXIT

loop=$(attach_image "$file" read-only)
wait_for_device "${loop}p$root_partition"
mnt=$(mktemp -d)
mount -o ro "${loop}p$root_partition" "$mnt"
if [[ $READ_ONLY == yes ]]; then
  wait_for_device "${loop}p$((root_partition + 1))"
fi
# The base's other partitions and, on a read-only root, the data partition, as the fstab has them.
mount_by_fstab "$image" "$mnt" "$loop" "${loop}p$root_partition" read-only
if [[ $READ_ONLY == yes ]]; then
  mountpoint -q "$mnt$IMG_DATA" || die "$image's data partition isn't where its fstab puts it, $IMG_DATA"
  for path in $KEEP; do
    mount --bind "$mnt$IMG_DATA$path" "$mnt$path"
    mount -o remount,bind,ro "$mnt$path"
  done
fi

# Every problem at once: the root's, then sshd's.
passed=yes
"$here/inspect-root.sh" --plan "$plan" --image "$image" --root "$mnt" || passed=no

# sshd -t, as the image's own sshd reads its configuration. The key lives in a tmpfs on /run.
if [[ -x $mnt/usr/sbin/sshd ]]; then
  mount -t proc proc "$mnt/proc"
  mount --rbind /dev "$mnt/dev"
  # So unmounting the image's /dev never reaches this machine's own.
  mount --make-rslave "$mnt/dev"
  mount -t tmpfs tmpfs "$mnt/run"
  # sshd refuses to start without its privilege separation folder, which systemd makes at boot.
  mkdir -p "$mnt/run/sshd" "$mnt/run/paddock-inspect"
  chroot "$mnt" /usr/bin/ssh-keygen -q -t ed25519 -N "" -C "" -f /run/paddock-inspect/host_key ||
    die "$image: couldn't make a host key with its ssh-keygen, to test sshd's configuration"
  if output=$(chroot "$mnt" /usr/sbin/sshd -t -f /etc/ssh/sshd_config -h /run/paddock-inspect/host_key 2>&1); then
    say "$image's sshd takes its configuration"
  else
    say "$image's sshd refuses its configuration (sshd -t):"$'\n'"$output"
    passed=no
  fi
fi
[[ $passed == yes ]] || die "$image doesn't pass its inspection: fix what's above, then build it again"
say "inspected $file"
