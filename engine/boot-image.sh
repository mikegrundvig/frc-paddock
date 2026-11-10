#!/usr/bin/env bash
# boot-image.sh: boots an image build-image.sh built, after its inspection and before any computer
# is stamped from it or it's released, and runs the image's boot check (boot.check in paddock.yaml)
# in it once it has finished starting. An image without one isn't booted.
#
#   sudo boot-image.sh --plan DIR --image NAME --config-dir DIR IMAGE.img
#
# Boots a throwaway copy, stamped as one of the image's computers (the first by name), so the image
# itself is unchanged. The copy boots in a container (systemd-nspawn --boot) with its root read-only
# and, on a read-only root, its data partition at /data, as that computer has them; with no network
# but its own loopback; and without its other partitions, which a container's systemd doesn't mount.
# Once systemd says the boot has finished, this names the units that failed (some need the board
# itself), then runs the check with bash, as root, inside the container, with PADDOCK_IMAGE set: its
# exit status is the boot's. Then the container is shut down and the copy removed.
#
# Needs root, losetup, systemd-nspawn and machinectl (systemd-container), and nsenter, on a machine
# of the image's architecture. PADDOCK_BOOT_TIMEOUT (seconds, 300 by default) is how long the boot
# may take.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" config_dir="" file=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --config-dir) need_value "$@"; config_dir=$2; shift 2 ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1" ;;
    *) file=$1; shift ;;
  esac
done
[[ -n $plan && -n $image && -n $config_dir ]] || die "--plan, --image, and --config-dir are required"
[[ -f $file ]] || die "no image file at '$file'"
load_image "$plan" "$image"
if [[ -z $BOOT_CHECK ]]; then
  say "$image has no boot check (boot.check in paddock.yaml), so it isn't booted"
  exit 0
fi
check=$config_dir/$BOOT_CHECK
[[ -f $check ]] || die "no boot check at $check: --config-dir must be paddock.yaml's folder"
((EUID == 0)) || die "needs root: it mounts a copy of the image and boots it"
for tool in losetup systemd-nspawn machinectl nsenter; do
  command -v "$tool" >/dev/null || die "needs $tool (systemd-nspawn and machinectl are in systemd-container)"
done
case $ARCH:$(uname -m) in
  arm64:aarch64 | amd64:x86_64) ;;
  *) die "$image is for $ARCH, and this machine is $(uname -m): boot it on a machine of its own architecture" ;;
esac
timeout=${PADDOCK_BOOT_TIMEOUT:-300}
[[ $timeout =~ ^[1-9][0-9]*$ ]] || die "PADDOCK_BOOT_TIMEOUT '$timeout' isn't a number of seconds"

# The computer whose copy boots: the first of the image's, by name.
computer=""
for env in "$plan"/computers/*.env; do
  if (load_computer "$plan" "$(basename "$env" .env)" && [[ $COMPUTER_IMAGE == "$image" ]]); then
    computer=$(basename "$env" .env)
    break
  fi
done
[[ -n $computer ]] || die "no computer in the plan uses $image, so there's no copy of it to boot"

copy=${file%.img}.boot.img
machine=paddock-$image
mnt="" data="" loop="" nspawn=""
log=$(mktemp)
cleanup() {
  local i
  if [[ -n $nspawn ]] && kill -0 "$nspawn" 2>/dev/null; then
    # systemd-nspawn shuts the container down cleanly on SIGTERM.
    kill -TERM "$nspawn" 2>/dev/null || true
    for ((i = 0; i < 60; i++)); do
      kill -0 "$nspawn" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$nspawn" 2>/dev/null || true
    wait "$nspawn" 2>/dev/null || true
  fi
  for dir in "$data" "$mnt"; do
    [[ -n $dir ]] || continue
    if mountpoint -q "$dir"; then
      umount "$dir" 2>/dev/null || umount --lazy "$dir" || say "couldn't unmount $dir"
    fi
    rmdir "$dir" 2>/dev/null || true
  done
  if [[ -n $loop ]]; then
    losetup --detach "$loop" || say "couldn't detach $loop"
  fi
  rm -f "$copy" "$log"
}
trap cleanup EXIT

say "$image: booting a copy, stamped as $computer"
cp --sparse=always "$file" "$copy"
"$here/stamp-image.sh" --plan "$plan" --computer "$computer" "$copy"

root_partition=$(partition_count "$copy")
if [[ $READ_ONLY == yes ]]; then
  root_partition=$((root_partition - 1))
fi
((root_partition > 0)) || die "$copy has no root partition"
loop=$(attach_image "$copy")
wait_for_device "${loop}p$root_partition"
mnt=$(mktemp -d)
mount "${loop}p$root_partition" "$mnt"
# The container's root is read-only (--read-only); the data partition, bound at /data, isn't, and
# the kept paths' binds in the image's fstab take it from there.
binds=()
if [[ $READ_ONLY == yes ]]; then
  wait_for_device "${loop}p$((root_partition + 1))"
  data=$(mktemp -d)
  mount "${loop}p$((root_partition + 1))" "$data"
  binds+=(--bind="$data:$IMG_DATA")
fi

systemd-nspawn --quiet --boot --directory="$mnt" --read-only "${binds[@]}" \
  --machine="$machine" --register=yes --private-network --console=passive \
  --resolv-conf=off --timezone=off --link-journal=no >"$log" 2>&1 &
nspawn=$!

# Ends the boot as failed, with the container's journal (warnings and worse) once it has one.
boot_failed() {
  if [[ -n $leader ]]; then
    say "$image's journal, warnings and worse:"
    "${enter[@]}" journalctl --boot --no-pager --priority=warning --lines=100 >&2 || true
  fi
  die "$@"
}

# Waits for the container's systemd to say its boot has finished: running, or degraded with units
# that failed. Each try is cut short, so a boot that hangs stops at the deadline.
deadline=$((SECONDS + timeout))
leader="" state="" enter=()
while :; do
  kill -0 "$nspawn" 2>/dev/null || die "$image's container stopped while it booted:"$'\n'"$(tail -n 40 "$log")"
  ((SECONDS < deadline)) || boot_failed "$image didn't finish booting in ${timeout}s (its systemd says: ${state:-nothing})"
  if [[ -z $leader ]]; then
    leader=$(machinectl show "$machine" --property=Leader --value 2>/dev/null || true)
  fi
  if [[ -n $leader ]]; then
    enter=(nsenter --target "$leader" --all --root --wd -- env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin)
    state=$(timeout 10 "${enter[@]}" systemctl is-system-running --wait 2>/dev/null || true)
    case $state in
      running | degraded) break ;;
      maintenance | stopping) boot_failed "$image booted into $state, not to its default target" ;;
    esac
  fi
  sleep 1
done
say "$image booted as $computer: its systemd says $state"
failed=$("${enter[@]}" systemctl list-units --failed --plain --no-legend --no-pager | awk '{ print $1 }' | paste -sd ' ')
[[ -z $failed ]] || say "units that failed in the container (some need the board itself): $failed"

say "running $BOOT_CHECK in $image"
if ! "${enter[@]}" PADDOCK_IMAGE="$image" bash -s <"$check"; then
  boot_failed "$image's boot check ($BOOT_CHECK) failed: fix what's above, then build it again"
fi
say "booted $image, and its boot check passed"
