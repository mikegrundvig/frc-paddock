#!/usr/bin/env bash
# fetch.sh: downloads what a recipe builds a board's common image from, each checked against its
# lock or its sha256: the board's base image, the recipe's inputs (RECIPE_INPUTS: PhotonVision's
# jar, say), and the packages the team's images get. Nothing unchecked is ever used: a download
# whose SHA-256 isn't the one given fails here.
#
#   fetch.sh --recipe-dir DIR --board BOARD --packages FILE --out DIR [--no-image]
#
#   --packages  the team's packages, as plan.sh lists them (packages.list): a sha256 and a URL a
#               line
#
# Writes OUT/base.img.xz (unless --no-image); OUT/inputs/, each input by its name; and
# OUT/packages/, each package as NN-<its file's name>, numbered in the list's order. Needs curl,
# sha256sum, and python3, which reads the locks (JSON): it runs on the recipe's runner, which may
# have no yq.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

recipe_dir="" board="" packages="" out="" image=yes
while (($#)); do
  case $1 in
    --recipe-dir) recipe_dir=${2:?}; shift 2 ;;
    --board) board=${2:?}; shift 2 ;;
    --packages) packages=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --no-image) image=no; shift ;;
    -h | --help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
load_recipe "$recipe_dir"
load_board "$board"
lock=$RECIPE_DIR/$RECIPE_LOCK
[[ -f $lock ]] || die "no lock at $lock"
[[ -f $packages ]] || die "no package list at '$packages' (--packages)"
[[ -n $out ]] || die "--out is required"
mkdir -p "$out/inputs" "$out/packages"

# A value from a JSON lock, by its path's names (a missing one is empty).
json_get() {
  python3 - "$@" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for name in sys.argv[2:]:
    value = value.get(name, {}) if isinstance(value, dict) else {}
print(value if isinstance(value, str) else "")
PY
}

# Downloads a URL to a file and checks it, or fails saying which.
fetch() {
  local what=$1 url=$2 sum=$3 file=$4
  [[ $url == https://* ]] || die "$what's URL is missing or not https ('$url')"
  is_sha256 "$sum" || die "$what's sha256 is missing or a placeholder ('$sum')"
  if [[ -f $file ]] && sha256sum <"$file" | grep -q "^$sum "; then
    say "$what: already here, checked"
    return
  fi
  say "$what: downloading ${url##*/}"
  if ! curl --fail --location --silent --show-error --retry 3 --output "$file.part" "$url"; then
    rm -f "$file.part"
    die "$what couldn't be downloaded from $url${5:+: $5}"
  fi
  echo "$sum  $file.part" | sha256sum --check --strict --quiet ||
    die "$what isn't the one pinned: its SHA-256 differs from $sum"
  mv -f "$file.part" "$file"
}

if [[ $image == yes ]]; then
  fetch "$board's base image" "$(json_get "$lock" images "$board" url)" \
    "$(json_get "$lock" images "$board" sha256)" "$out/base.img.xz"
fi
for input in $RECIPE_INPUTS; do
  name=${input%%=*}
  IFS=. read -r -a path <<<"${input#*=.}"
  fetch "$name" "$(json_get "$lock" "${path[@]}" url)" "$(json_get "$lock" "${path[@]}" sha256)" \
    "$out/inputs/$name"
done
# The packages, numbered so they keep their order; any left from another list go.
wanted=() sums=() links=()
while read -r sum url <&3; do
  [[ -n $sum ]] || continue
  [[ $url =~ ^https://[A-Za-z0-9:/._~%+-]+\.deb$ ]] || die "$packages: '$url' isn't the https:// address of a .deb"
  wanted+=("$(printf '%02d-%s' "${#wanted[@]}" "${url##*/}")")
  sums+=("$sum")
  links+=("$url")
done 3<"$packages"
for file in "$out"/packages/*; do
  [[ -e $file && " ${wanted[*]} " != *" ${file##*/} "* ]] || continue
  rm -f "$file"
done
for i in "${!wanted[@]}"; do
  fetch "${links[$i]##*/}" "${links[$i]}" "${sums[$i]}" "$out/packages/${wanted[$i]}" \
    "its release must be public, and hold it"
done
say "fetched what $board's common image is built from, into $out"
