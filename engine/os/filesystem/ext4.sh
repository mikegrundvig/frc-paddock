# shellcheck shell=bash
# The ext4 adapter (os: filesystem: ext4): the root's filesystem, grown, trimmed and checked, and the
# data partition's. These run on the build machine, never in the chroot.

fs_check_base() {
  local type
  type=$(blkid -p -o value -s TYPE "$1" 2>/dev/null || true)
  [[ $type == ext4 ]] || echo "the root partition is ${type:-not a filesystem blkid knows}, not ext4"
  return 0
}

fs_grow() {
  e2fsck -pf "$1" || (($? < 4)) || die "the root on $1 has errors e2fsck can't fix"
  resize2fs "$1"
}

# Discards free blocks, so what the steps deleted (apt's downloads, say) ships as zeros.
fs_trim() {
  fstrim "$1" || say "couldn't trim $1: the image may be larger than it needs to be"
}

# Fails on any error, changing nothing.
fs_check() {
  e2fsck -fn "$1" >/dev/null
}

fs_type() {
  echo ext4
}

fs_data_options() {
  # Read-only on an error rather than spreading the damage; checked at boot (fstab's pass 2).
  echo "noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s"
}

# Makes a filesystem inside an image file: IMAGE OFFSET_BYTES SIZE_KIB LABEL [DIR], filled from DIR
# (owners and modes kept). Inode tables and journal are written now, not by the board's kernel.
fs_make() {
  local args=(-q -F -L "$4" -E "offset=$2,lazy_itable_init=0,lazy_journal_init=0,nodiscard")
  if [[ -n ${5-} ]]; then
    args+=(-d "$5")
  fi
  mkfs.ext4 "${args[@]}" "$1" "${3}k"
}
