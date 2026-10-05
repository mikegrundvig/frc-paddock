#!/usr/bin/env bash
# build-image.sh: builds an image, the one each of its computers is stamped from.
#
#   sudo build-image.sh --plan DIR --image NAME --config-dir DIR --inputs DIR --out FILE.img
#
#   --config-dir  paddock.yaml's folder, bound read-only into the chroot for the steps
#   --inputs      what fetch.sh downloaded
#
# The base's last partition is its root, grown by grow:; its other partitions are mounted where its
# fstab says, so steps can change them. run-steps.sh and finish-root.sh run in a chroot, then
# layout.sh adds a read-only root's data partition. Another architecture needs qemu-user-static
# registered with binfmt_misc's "F" flag. Needs root, losetup, sfdisk, blkid, mount, chroot, fstrim,
# and the filesystem adapter's tools.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" config_dir="" inputs="" out=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --config-dir) need_value "$@"; config_dir=$2; shift 2 ;;
    --inputs) need_value "$@"; inputs=$2; shift 2 ;;
    --out) need_value "$@"; out=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $plan && -n $image && -n $out ]] || die "--plan, --image, and --out are required"
[[ -n $config_dir && -d $config_dir ]] || die "--config-dir must be paddock.yaml's folder"
[[ -n $inputs && -d $inputs/packages ]] || die "--inputs must be what fetch.sh downloaded"
load_image "$plan" "$image"
((EUID == 0)) || die "needs root: it mounts the image"
for tool in losetup sfdisk blkid mount chroot fstrim; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
plan=$(cd "$plan" && pwd)
config_dir=$(cd "$config_dir" && pwd)
inputs=$(cd "$inputs" && pwd)

case $BASE_FORMAT in
  xz) base=$inputs/base.img.xz unpack=(xz -dc) ;;
  gz) base=$inputs/base.img.gz unpack=(gzip -dc) ;;
  img) base=$inputs/base.img unpack=(cat) ;;
esac
[[ -f $base ]] || die "no base at $base (fetch.sh downloads it)"
keep=${out%.img}.keep
mnt="" loop="" resolv=""

# Every process whose root is the chroot (a daemon a step left running): it would hold the image.
kill_chroot_processes() {
  local proc pid found=()
  for proc in /proc/[0-9]*; do
    [[ $(readlink "$proc/root" 2>/dev/null) == "$mnt" ]] || continue
    pid=${proc#/proc/}
    found+=("$pid ($(cat "$proc/comm" 2>/dev/null))")
    kill -TERM "$pid" 2>/dev/null || true
  done
  ((${#found[@]})) || return 0
  say "stopping what the steps left running: ${found[*]}"
  sleep 2
  for proc in /proc/[0-9]*; do
    [[ $(readlink "$proc/root" 2>/dev/null) == "$mnt" ]] && kill -KILL "${proc#/proc/}" 2>/dev/null
  done
  return 0
}

# Unmounts and detaches; on a busy mount, lazily, so nothing stays attached on the build machine.
cleanup() {
  if [[ -n $mnt ]]; then
    kill_chroot_processes
    if mountpoint -q "$mnt"; then
      umount --recursive "$mnt" 2>/dev/null || {
        say "$mnt is busy: unmounting it lazily"
        umount --recursive --lazy "$mnt" || true
      }
    fi
    rmdir "$mnt" 2>/dev/null || true
    mnt=""
  fi
  if [[ -n $loop ]]; then
    losetup --detach "$loop" || say "couldn't detach $loop"
    loop=""
  fi
}
trap cleanup EXIT

# --- The base, unpacked (sparse) and grown. Its root is its last partition. ---
say "$image: unpacking ${BASE_URL##*/}"
"${unpack[@]}" "$base" | dd of="$out" bs=4M iflag=fullblock conv=sparse status=none
root_partition=$(partition_count "$out")
((root_partition > 0)) || die "$image's base has no partition table"
if ((GROW_MB > 0)); then
  truncate -s "+${GROW_MB}M" "$out"
  if [[ $(sfdisk --dump "$out" | sed -n 's/^label: *//p') == gpt ]]; then
    sfdisk --quiet --relocate gpt-bak-std "$out"
  fi
  echo ', +' | sfdisk --quiet --no-reread --no-tell-kernel -N "$root_partition" "$out"
fi
loop=$(attach_image "$out")
root_dev=${loop}p$root_partition
wait_for_device "$root_dev"
problems=$(fs_check_base "$root_dev" || true)
[[ -z $problems ]] || die "$image's base: its last partition is its root, but $problems"
fs_grow "$root_dev"

# --- Mounted, with its other partitions where its fstab puts them. ---
mnt=$(mktemp -d)
mount "$root_dev" "$mnt"
# The base is the architecture from: says (its bash's ELF machine).
bash_bin=$mnt/usr/bin/bash
[[ -e $bash_bin ]] || bash_bin=$mnt/bin/bash
case $(od -An -t u2 -j 18 -N 2 "$bash_bin" 2>/dev/null | tr -d ' ') in
  183) base_arch=arm64 ;;
  62) base_arch=amd64 ;;
  *) base_arch=unknown ;;
esac
[[ $base_arch == "$ARCH" ]] || die "$image's base is $base_arch, but from.arch says $ARCH"
if [[ -f $mnt/etc/fstab ]]; then
  while read -r source point type _; do
    [[ $source =~ ^(PARTUUID|PARTLABEL|UUID|LABEL)=(.+)$ ]] || continue
    [[ $point == /* && $point != / && $type != swap ]] || continue
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    # blkid's low-level probe calls the partition table's names PART_ENTRY_*.
    case $key in
      PARTUUID) key=PART_ENTRY_UUID ;;
      PARTLABEL) key=PART_ENTRY_NAME ;;
    esac
    [[ $point =~ ^(/[A-Za-z0-9._@+-]+)+$ && ! $point =~ /\.\.?(/|$) ]] ||
      die "$image's fstab mounts something at '$point', which isn't a plain path"
    matched=no
    for dev in "$loop"p*; do
      [[ $dev != "$root_dev" ]] || continue
      probed=$(blkid -p -o value -s "$key" "$dev" 2>/dev/null || true)
      # UUIDs in either case; labels exactly.
      if [[ $key == *UUID ]]; then
        probed=${probed,,} value=${value,,}
      fi
      if [[ -n $probed && $probed == "$value" ]]; then
        say "mounting ${dev##*/} at $point, as the image's fstab does"
        mkdir -p "$mnt$point"
        [[ ! -L $mnt$point ]] || die "$image's fstab mount point $point is a link"
        mount "$dev" "$mnt$point"
        matched=yes
      fi
    done
    [[ $matched == yes ]] || say "warning: $image's fstab mounts $source at $point, which is none of its partitions; steps that write there write into the root"
  done < <(grep -Ev '^[[:space:]]*(#|$)' "$mnt/etc/fstab")
fi

# --- The steps, in a chroot. ---
mount -t proc proc "$mnt/proc"
mount -t sysfs sys "$mnt/sys"
mount --rbind /dev "$mnt/dev"
# So unmounting the chroot's /dev never reaches the machine's own.
mount --make-rslave "$mnt/dev"
mount -t tmpfs tmpfs "$mnt/run"
bind_ro() {
  mkdir -p "$mnt$2"
  mount --bind "$1" "$mnt$2"
  mount -o remount,bind,ro "$mnt$2"
}
bind_ro "$here" "$RUN_DIR/engine"
bind_ro "$plan" "$RUN_DIR/plan"
bind_ro "$config_dir" "$RUN_DIR/config"
bind_ro "$inputs" "$RUN_DIR/inputs"
rm -rf "$keep"
mkdir -p "$keep" "$mnt$RUN_DIR/keep"
mount --bind "$keep" "$mnt$RUN_DIR/keep"

# The build machine's DNS for the steps. Afterwards: the base's own back, unless a step wrote its
# own; none, if the base had none.
resolv=$(mktemp)
cp /etc/resolv.conf "$resolv"
if [[ -e $mnt/etc/resolv.conf || -L $mnt/etc/resolv.conf ]]; then
  mv -f "$mnt/etc/resolv.conf" "$mnt/etc/resolv.conf.paddock-saved"
fi
# Readable by all: apt downloads as its own unprivileged user.
install -m 0644 "$resolv" "$mnt/etc/resolv.conf"

in_chroot() {
  chroot "$mnt" /bin/bash "$RUN_DIR/engine/$1" --plan "$RUN_DIR/plan" --image "$image" "${@:2}"
}
in_chroot run-steps.sh --config-dir "$RUN_DIR/config" --inputs "$RUN_DIR/inputs"

if [[ -f $mnt/etc/resolv.conf && ! -L $mnt/etc/resolv.conf ]] && cmp -s "$resolv" "$mnt/etc/resolv.conf"; then
  rm -f "$mnt/etc/resolv.conf"
  if [[ -e $mnt/etc/resolv.conf.paddock-saved || -L $mnt/etc/resolv.conf.paddock-saved ]]; then
    mv -f "$mnt/etc/resolv.conf.paddock-saved" "$mnt/etc/resolv.conf"
  fi
else
  say "a step wrote /etc/resolv.conf: keeping it"
  rm -f "$mnt/etc/resolv.conf.paddock-saved"
fi
rm -f "$resolv"

in_chroot finish-root.sh --keep-out "$RUN_DIR/keep" --root-id "UUID=$(blkid -p -o value -s UUID "$root_dev")"
kill_chroot_processes
fs_trim "$mnt"
sync
cleanup

# --- The data partition. ---
if [[ $READ_ONLY == yes ]]; then
  "$here/layout.sh" --plan "$plan" --image "$image" --keep "$keep" "$out"
fi
rm -rf "$keep"

# --- Every filesystem checked, unchanged. ---
loop=$(attach_image "$out")
wait_for_device "${loop}p$root_partition"
fs_check "${loop}p$root_partition" || die "$image's root has errors after its build"
if [[ $READ_ONLY == yes ]]; then
  wait_for_device "${loop}p$((root_partition + 1))"
  fs_check "${loop}p$((root_partition + 1))" || die "$image's data partition has errors after its build"
fi
cleanup
say "built $image: $out"
