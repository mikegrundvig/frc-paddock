#!/usr/bin/env bash
# finish-root.sh: readies an image's root after its steps, before computers are stamped from it.
# build-image.sh runs it as root inside the image's chroot.
#
#   finish-root.sh --plan DIR --image NAME [--root DIR] [--keep-out DIR] [--root-id ID]
#
#   --keep-out  read-only root: where kept paths' contents go (KEEP-OUT/<path>), for layout.sh
#   --root-id   UUID=... of the root, for a base whose fstab has no root line
#
# Checks nothing but the network adapter configures Ethernet, and clears the machine ID. For a
# read-only root it rewrites /etc/fstab: the root read-only, the data partition at /data, kept paths
# bound from it, RAM paths on tmpfs, each line after its parent's. Rerunning replaces its own block.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" target=/ keep_out="" root_id=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --root) need_value "$@"; target=$2; shift 2 ;;
    --keep-out) need_value "$@"; keep_out=$2; shift 2 ;;
    --root-id) need_value "$@"; root_id=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $plan && -n $image ]] || die "--plan and --image are required"
load_image "$plan" "$image"
target=$(cd "$target" && pwd)
root=${target%/}

problems=$(network_check_result "$target" || true)
if [[ -n $problems ]]; then
  die "$image's steps leave the network to more than its network adapter ($OS_NETWORK):"$'\n'"  - ${problems//$'\n'/$'\n'  - }"
fi
init_clear_machine_id "$target"

if [[ $READ_ONLY != yes ]]; then
  say "finished $image's root"
  exit 0
fi
[[ -n $keep_out ]] || die "$image has a read-only root: --keep-out is required"
mkdir -p "$keep_out"
keep_out=$(cd "$keep_out" && pwd)

fstab=$root/etc/fstab
[[ -f $fstab ]] || : >"$fstab"
# The base's own lines, without an earlier run's block.
base_lines=$(awk -v begin="$FSTAB_BEGIN" -v end="$FSTAB_END" '
  $0 == begin { skip = 1; next }
  skip && $0 == end { skip = 0; next }
  !skip' "$fstab")

owned="$IMG_DATA $KEEP $RAM"
# The base's other mount points (a boot partition, say) can't be kept: their files aren't the
# root's. One this block replaces (the base's own /tmp, say) is fine.
while read -r _ point _; do
  [[ $point == /* && $point != / && " $owned " != *" $point "* ]] || continue
  for path in $KEEP; do
    overlaps "$path" "$point" && die "$image keeps $path, but the base mounts $point there (its /etc/fstab)"
  done
done < <(grep -Ev '^[[:space:]]*(#|$)' <<<"$base_lines")
for path in $KEEP; do
  [[ ! -e $root$path || -d $root$path ]] || die "$image keeps $path, which is a file in the image: keep its folder"
done

roots=$(awk '!/^[[:space:]]*#/ && NF >= 3 && $2 == "/"' <<<"$base_lines" | wc -l)
((roots <= 1)) || die "$image's /etc/fstab has $roots lines for the root (/)"
if ((roots == 0)); then
  [[ $root_id =~ ^(UUID|PARTUUID|LABEL)=[A-Za-z0-9._-]+$ ]] ||
    die "$image's /etc/fstab has no line for the root (/), and no --root-id to write one"
  say "$image's /etc/fstab has no line for the root: adding one, by $root_id"
fi

# A directory's mode in the image (from the base, before any mkdir), or the default.
mode_of() {
  if [[ -d $root$1 ]]; then
    stat -c %a "$root$1"
  else
    echo "$2"
  fi
}
declare -A modes=()
for path in $RAM; do
  case $path in
    /tmp | /var/tmp) modes[$path]=1777 ;;
    *) modes[$path]=$(mode_of "$path" 755) ;;
  esac
done

{
  # The base's lines: its root's made read-only, any for a path this block mounts dropped.
  awk -v owned="$owned" '
    BEGIN { n = split(owned, m, " "); for (i = 1; i <= n; i++) mine[m[i]] = 1 }
    /^[[:space:]]*#/ || NF < 3 { print; next }
    $2 in mine { next }
    $2 == "/" { $4 = "ro,noatime"; if (NF < 6) { $5 = "0"; $6 = "1" } }
    { print }
  ' <<<"$base_lines"
  if ((roots == 0)); then
    printf '%s / %s ro,noatime 0 1\n' "$root_id" "$(fs_type)"
  fi
  echo "$FSTAB_BEGIN"
  printf 'LABEL=%s %s %s %s 0 2\n' "$DATA_LABEL" "$IMG_DATA" "$(fs_type)" "$(fs_data_options)"
  # Each mount after its parent's, so any init (not only systemd) mounts them in a working order.
  for path in $KEEP $RAM; do
    printf '%s %s\n' "$(tr -cd '/' <<<"$path" | wc -c)" "$path"
  done | sort -n -k1,1 -k2,2 | while read -r _ path; do
    if [[ " $KEEP " == *" $path "* ]]; then
      printf '%s%s %s none bind,nofail,x-systemd.requires-mounts-for=%s 0 0\n' "$IMG_DATA" "$path" "$path" "$IMG_DATA"
    else
      printf 'tmpfs %s tmpfs mode=%s,nosuid,nodev 0 0\n' "$path" "${modes[$path]}"
    fi
  done
  echo "$FSTAB_END"
} | put "$fstab" 0644

# Mount points, and each kept path's contents moved to what becomes the data partition.
mkdir -p "$root$IMG_DATA"
for path in $RAM; do
  if [[ ! -d $root$path ]]; then
    mkdir -p "$root$path"
    chmod "${modes[$path]}" "$root$path"
  fi
done
for path in $KEEP; do
  mkdir -p "$root$path" "$keep_out$path"
  chmod "$(stat -c %a "$root$path")" "$keep_out$path"
  if ((EUID == 0)); then
    chown "$(stat -c %u:%g "$root$path")" "$keep_out$path"
  fi
  cp -a "$root$path/." "$keep_out$path/"
  find "$root$path" -mindepth 1 -delete
done
say "finished $image's root: read-only, keeping ${KEEP:-nothing} on $IMG_DATA, with ${RAM:-nothing} in RAM"
