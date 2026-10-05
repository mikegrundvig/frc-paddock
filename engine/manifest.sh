#!/usr/bin/env bash
# manifest.sh: writes a release's SHA256SUMS and manifest.json.
#
#   manifest.sh DIR [--notice FILE]
#
# DIR holds each computer's NAME.img.xz beside its NAME.stamp.json (stamp.sh --stamp-out); --notice
# is the team's notice, in DIR. SHA256SUMS covers every image and the notice; manifest.json is the
# release, its commit, and each computer's record with its file and the file's SHA-256. Fails if the
# images aren't of one release and commit. Needs yq.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

dir="" notice=""
while (($#)); do
  case $1 in
    --notice) need_value "$@"; notice=$2; shift 2 ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1" ;;
    *) dir=$1; shift ;;
  esac
done
[[ -d $dir ]] || die "no folder '$dir'"
[[ -z $notice || -f $dir/$notice ]] || die "no notice $notice in $dir"
require_yq

entries=()
sums=""
shopt -s nullglob
for image in "$dir"/*.img.xz; do
  [[ -f ${image%.img.xz}.stamp.json ]] || die "${image##*/} has no stamp (${image%.img.xz}.stamp.json)"
done
for stamp in "$dir"/*.stamp.json; do
  image=${stamp%.stamp.json}.img.xz
  [[ -f $image ]] || die "${stamp##*/} has no image (${image##*/})"
  sum=$(sha256sum <"$image" | cut -c1-64)
  sums+="$sum  ${image##*/}"$'\n'
  entries+=("$(FILE=${image##*/} SUM=$sum yq -p json -o=json -I=0 \
    '. + {"file": strenv(FILE), "fileSha256": strenv(SUM)}' "$stamp")")
done
((${#entries[@]})) || die "no images in $dir"
if [[ -n $notice ]]; then
  sums+="$(sha256sum <"$dir/$notice" | cut -c1-64)  $notice"$'\n'
fi
all="[$(IFS=,; echo "${entries[*]}")]"
for field in release commit; do
  [[ $(FIELD=$field yq -p json -o yaml -r '[.[] | .[strenv(FIELD)]] | unique | length' <<<"$all") == 1 ]] ||
    die "the images aren't all of one $field"
done

LC_ALL=C sort -k2 <<<"${sums%$'\n'}" >"$dir/SHA256SUMS"
yq -p json -o=json -I=2 '{
  "schema": 1,
  "release": .[0].release,
  "commit": .[0].commit,
  "builtAt": .[0].builtAt,
  "computers": (sort_by(.hostname) | map(del(.release) | del(.commit) | del(.builtAt)))
}' <<<"$all" >"$dir/manifest.json"
say "wrote SHA256SUMS and manifest.json for ${#entries[@]} computer(s)"
