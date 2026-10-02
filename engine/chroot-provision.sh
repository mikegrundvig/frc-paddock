#!/usr/bin/env bash
# chroot-provision.sh: runs a command in a chroot of a base image's root, as a recipe's provisioning
# needs: the root grown first by the headroom asked for, and the image's root mounted with /proc,
# /sys, /dev, a tmpfs /run, and the network's DNS; a folder of the machine's bind-mounted at
# /tmp/build, where the command runs. Everything is unmounted and detached after, even on a failure.
#
#   sudo chroot-provision.sh --image FILE --root-partition N --grow-mb N --bind DIR -- COMMAND...
#
# On a machine of the image's architecture (GitHub's ARM runners, for an arm64 image), nothing is
# emulated; on another, the kernel needs qemu-user-static registered in binfmt_misc with its "F"
# flag. Needs root, sfdisk, losetup, e2fsck, resize2fs, and mount.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

image="" partition="" grow="" bind=""
while (($#)); do
  case $1 in
    --image) image=${2:?}; shift 2 ;;
    --root-partition) partition=${2:?}; shift 2 ;;
    --grow-mb) grow=${2:?}; shift 2 ;;
    --bind) bind=${2:?}; shift 2 ;;
    --) shift; break ;;
    *) die "unknown option: $1" ;;
  esac
done
(($#)) || die "no command to run in the chroot"
[[ -f $image ]] || die "no image file at '$image'"
[[ $partition =~ ^[1-9]$ ]] || die "--root-partition must be a partition's number"
[[ $grow =~ ^[0-9]+$ ]] || die "--grow-mb must be a number of MiB"
[[ -d $bind ]] || die "--bind must be a folder"
((EUID == 0)) || die "needs root: it mounts the image"
bind=$(cd "$bind" && pwd)

mnt="" loop=""
# Unmounts the chroot and detaches the image; says what's left if it can't.
cleanup() {
  local status=0
  if [[ -n $mnt ]]; then
    if [[ -e $mnt/etc/resolv.conf.coproc-saved ]]; then
      mv -f "$mnt/etc/resolv.conf.coproc-saved" "$mnt/etc/resolv.conf" || status=1
    fi
    if mountpoint -q "$mnt"; then
      umount --recursive "$mnt" || { say "couldn't unmount $mnt"; status=1; }
    fi
    if ((status == 0)); then
      rmdir "$mnt" || status=1
    fi
  fi
  if [[ -n $loop ]] && ((status == 0)); then
    losetup --detach "$loop" || { say "couldn't detach $loop"; status=1; }
  fi
  if ((status == 0)); then
    mnt="" loop=""
  fi
  return "$status"
}
trap 'cleanup || say "left mounted: ${mnt:-nothing}; attached: ${loop:-nothing}"' EXIT

# The root grown by the headroom asked for, to the image's new end.
if ((grow > 0)); then
  truncate -s "+${grow}M" "$image"
  if [[ $(sfdisk --dump "$image" | sed -n 's/^label: *//p') == gpt ]]; then
    sfdisk --quiet --relocate gpt-bak-std "$image"
  fi
  echo ', +' | sfdisk --quiet --no-reread --no-tell-kernel -N "$partition" "$image"
fi
loop=$(losetup --find --show --partscan "$image")
udevadm settle 2>/dev/null || true
root_dev="${loop}p$partition"
e2fsck -pf "$root_dev" || (($? < 4)) || die "the image's root has errors e2fsck can't fix"
resize2fs "$root_dev"

mnt=$(mktemp -d)
mount "$root_dev" "$mnt"
mount -t proc proc "$mnt/proc"
mount -t sysfs sys "$mnt/sys"
mount --rbind /dev "$mnt/dev"
# So unmounting the chroot's /dev never reaches the machine's own.
mount --make-rslave "$mnt/dev"
mount -t tmpfs tmpfs "$mnt/run"
mkdir -p "$mnt/tmp/build"
mount --bind "$bind" "$mnt/tmp/build"
if [[ -e $mnt/etc/resolv.conf || -L $mnt/etc/resolv.conf ]]; then
  mv -f "$mnt/etc/resolv.conf" "$mnt/etc/resolv.conf.coproc-saved"
fi
cp /etc/resolv.conf "$mnt/etc/resolv.conf"

say "running in the chroot of $image: $*"
chroot "$mnt" /bin/bash -c 'cd /tmp/build && exec "$@"' bash "$@"
sync
cleanup || die "couldn't unmount the image: $image is still attached"
say "provisioned $image"
