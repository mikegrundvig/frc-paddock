#!/usr/bin/env bash
# fetch.sh: downloads an image's base, packages and downloads, each checked against its SHA-256.
# Nothing unchecked is ever used.
#
#   fetch.sh --plan DIR --image NAME --out DIR
#
# Writes OUT/base.img(.xz|.gz), OUT/packages/NN-<file> and OUT/downloads/NN-<file>, numbered in
# step order. A file already there and right isn't fetched again. Needs curl and sha256sum.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" out=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --out) need_value "$@"; out=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $plan && -n $image && -n $out ]] || die "--plan, --image, and --out are required"
load_image "$plan" "$image"
mkdir -p "$out/packages" "$out/downloads"

# Downloads a URL to a file and checks it. A stalled transfer fails within a minute; a broken one
# is retried, resuming where it stopped.
fetch() {
  local what=$1 url=$2 sum=$3 file=$4 actual attempt
  if [[ -f $file ]] && sha256sum <"$file" | grep -q "^$sum "; then
    say "$what: already here, checked"
    return
  fi
  say "$what: downloading ${url##*/}"
  # A part left by an earlier run may be of something else: only this run's parts are resumed.
  rm -f "$file.part"
  for attempt in 1 2 3; do
    if curl --fail --location --silent --show-error --continue-at - \
      --connect-timeout 30 --speed-limit 65536 --speed-time 60 \
      --retry 5 --retry-delay 5 --retry-all-errors --output "$file.part" "$url"; then
      break
    fi
    ((attempt < 3)) || {
      rm -f "$file.part"
      die "$what couldn't be downloaded from $url: is it public, and is the URL right?"
    }
    say "$what: download interrupted, resuming"
  done
  actual=$(sha256sum <"$file.part" | cut -c1-64)
  if [[ $actual != "$sum" ]]; then
    rm -f "$file.part"
    die "$what isn't the one paddock.yaml gives: its SHA-256 is $actual, not $sum (if the URL changed, its sha256 must too)"
  fi
  mv -f "$file.part" "$file"
}

case $BASE_FORMAT in
  img) base=$out/base.img ;;
  *) base=$out/base.img.$BASE_FORMAT ;;
esac
fetch "$image's base" "$BASE_URL" "$BASE_SHA256" "$base"

# Packages, then downloads, each numbered in step order; anything left from another plan goes.
for kind in package download; do
  dir=$out/${kind}s
  wanted=() sums=() links=()
  while IFS=$'\t' read -r step sum url _ <&3; do
    [[ $step == "$kind" ]] || continue
    wanted+=("$(printf '%02d-%s' "${#wanted[@]}" "${url##*/}")")
    sums+=("$sum")
    links+=("$url")
  done 3<"$IMAGE_DIR/steps.list"
  for file in "$dir"/*; do
    [[ -e $file && " ${wanted[*]} " != *" ${file##*/} "* ]] || continue
    rm -f "$file"
  done
  for i in "${!wanted[@]}"; do
    fetch "${links[$i]##*/}" "${links[$i]}" "${sums[$i]}" "$dir/${wanted[$i]}"
  done
done
say "fetched what $image is built from, into $out"
