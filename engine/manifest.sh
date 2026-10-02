#!/usr/bin/env bash
# manifest.sh: writes a release's SHA256SUMS and manifest.json, from its images and their stamps.
#
#   manifest.sh DIR
#
# DIR holds each computer's image, NAME.img.xz, beside its stamp, NAME.stamp.json (what stamp.sh
# wrote with --stamp-out). Writes into DIR:
#   SHA256SUMS     one line per file of the release (the images, and NOTICE.md when it's there), as
#                  sha256sum writes them, so `sha256sum -c SHA256SUMS` (or PowerShell's
#                  Get-FileHash, by eye) checks a download
#   manifest.json  the release (team, release name, recipe hash) and each computer: name, address,
#                  image file, image sha256, its stamp's labels (the software's version, the board,
#                  the settings hash), and the sha256 of the common image it was stamped from, when
#                  NAME.common-sha256 holds it
# Fails if the images don't all come from one team, release, and recipe, or an image has no stamp.
# Needs yq (mikefarah's, version 4).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

dir=${1:?usage: manifest.sh DIR}
[[ -d $dir ]] || die "no directory '$dir'"
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
  # The common image's sha256, when the build left it beside the image (NAME.common-sha256).
  common=""
  if [[ -f ${stamp%.stamp.json}.common-sha256 ]]; then
    common=$(head -c 64 "${stamp%.stamp.json}.common-sha256")
    is_sha256 "$common" || die "${stamp%.stamp.json}.common-sha256 isn't a sha256"
  fi
  entries+=("$(IMAGE=${image##*/} SUM=$sum COMMON=$common yq -p json -o=json -I=0 \
    '. + {"image": strenv(IMAGE), "imageSha256": strenv(SUM)} |
      with(select(strenv(COMMON) != ""); .commonImageSha256 = strenv(COMMON))' "$stamp")")
done
((${#entries[@]})) || die "no images in $dir"
if [[ -f $dir/NOTICE.md ]]; then
  sums+="$(sha256sum <"$dir/NOTICE.md" | cut -c1-64)  NOTICE.md"$'\n'
fi
all="[$(IFS=,; echo "${entries[*]}")]"
for field in team version recipeHash; do
  [[ $(FIELD=$field yq -p json -o yaml -r '[.[] | .[strenv(FIELD)]] | unique | length' <<<"$all") == 1 ]] ||
    die "the images don't share one $field"
done

sort -k2 <<<"${sums%$'\n'}" >"$dir/SHA256SUMS"
yq -p json -o=json -I=2 '{
  "schema": 2,
  "team": .[0].team,
  "release": .[0].version,
  "recipeHash": .[0].recipeHash,
  "computers": (sort_by(.name) | map({
    "name": .name,
    "address": .address,
    "image": .image,
    "imageSha256": .imageSha256,
    "labels": (.labels // {})
  } + (with_entries(select(.key == "commonImageSha256")))))
}' <<<"$all" >"$dir/manifest.json"
say "wrote SHA256SUMS and manifest.json for ${#entries[@]} computers"
