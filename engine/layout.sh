#!/usr/bin/env bash
# layout.sh: adds the data partition to a read-only image, right after its root (its last
# partition), on the image file itself: no root, no loop devices.
#
#   layout.sh --plan DIR --image NAME [--keep DIR] IMAGE.img
#
#   --keep  what the data partition starts with: kept paths' contents, as finish-root.sh moved them
#
# The data partition is read-only.data's size, the filesystem adapter's format, labelled
# paddock-data. The rest of the drive stays unpartitioned. Safe to rerun. Needs sfdisk and the
# filesystem adapter's tools.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" keep="" file=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --keep) need_value "$@"; keep=$2; shift 2 ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1" ;;
    *) file=$1; shift ;;
  esac
done
[[ -n $plan && -n $image ]] || die "--plan and --image are required"
load_image "$plan" "$image"
[[ $READ_ONLY == yes ]] || die "$image has no read-only root, so no data partition"
[[ -f $file ]] || die "no image file at '$file'"
[[ -z $keep || -d $keep ]] || die "--keep must be a folder"
command -v sfdisk >/dev/null || die "needs sfdisk"

dump=$(sfdisk --dump "$file") || die "$file has no partition table sfdisk can read"
table=$(sed -n 's/^label: *//p' <<<"$dump")
sector=$(sed -n 's/^sector-size: *//p' <<<"$dump")
sector=${sector:-512}
[[ $table == dos || $table == gpt ]] || die "$file: partition table '$table', expected dos or gpt"
((sector == 512)) || die "$file: $sector-byte sectors, expected 512"

# "start size" per partition, in table order.
parts=$(awk -F'[:,]' '/: start=/ {
  start = ""; size = ""
  for (i = 2; i <= NF; i++) {
    split($i, kv, "=")
    gsub(/[[:space:]]/, "", kv[1]); gsub(/[[:space:]"]/, "", kv[2])
    if (kv[1] == "start") start = kv[2]
    else if (kv[1] == "size") size = kv[2]
  }
  print start, size
}' <<<"$dump")
count=$(grep -c . <<<"$parts" || true)
((count > 0)) || die "$file has no partitions"

mib=$((1024 * 1024 / sector))
align=$((ALIGN_MIB * mib))
data_size=$((DATA_MB * mib))

# Already laid out: the last partition is the data partition (its label says so).
read -r last_start last_size < <(sed -n "${count}p" <<<"$parts")
if ((last_size == data_size)) &&
  [[ $(blkid -p -O $((last_start * sector)) -o value -s LABEL "$file" 2>/dev/null || true) == "$DATA_LABEL" ]]; then
  say "$file is already laid out"
  exit 0
fi
if [[ $table == dos ]] && ((count >= 4)); then
  die "$file's root is its fourth partition: an MBR table has no room for a data partition after it"
fi

root_start=$last_start root_size=$last_size
data_start=$(((root_start + root_size + align - 1) / align * align))
end=$((data_start + data_size))
# GPT keeps a backup table in the drive's last sectors: leave a MiB for it.
if [[ $table == gpt ]]; then
  end=$((end + mib))
fi
if (($(stat -c %s "$file") < end * sector)); then
  truncate -s $((end * sector)) "$file"
  if [[ $table == gpt ]]; then
    sfdisk --quiet --relocate gpt-bak-std "$file"
  fi
fi

say "adding $DATA_LABEL ($DATA_MB MiB) after the root"
# The filesystem first, so a failure leaves no partition that looks laid out.
fs_make "$file" $((data_start * sector)) $((data_size * sector / 1024)) "$DATA_LABEL" "$keep"
if [[ $table == gpt ]]; then
  printf 'start=%s, size=%s, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="%s"\n' \
    "$data_start" "$data_size" "$DATA_LABEL"
else
  printf 'start=%s, size=%s, type=83\n' "$data_start" "$data_size"
fi | sfdisk --quiet --append --no-reread --no-tell-kernel "$file"
say "laid out $file ($table): the root, then $DATA_LABEL at sector $data_start"
