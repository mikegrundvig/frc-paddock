#!/usr/bin/env bash
# fetch.sh: downloads what a recipe builds a board's common image from, each checked against its
# lock: the board's base image, the recipe's inputs (RECIPE_INPUTS: PhotonVision's jar, say), and
# Spotter's agent for the recipe's architecture (spotter.lock). Nothing unchecked is ever used: a
# download whose SHA-256 isn't the lock's fails here.
#
#   fetch.sh --recipe-dir DIR --board BOARD --spotter-lock FILE --out DIR [--no-image]
#
# Writes OUT/base.img.xz (unless --no-image), and OUT/inputs/: each input by its name, and
# frc-spotter.deb. Needs curl, sha256sum, and python3, which reads the locks (JSON): it
# runs on the recipe's runner, which may have no yq.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

recipe_dir="" board="" spotter_lock="" out="" image=yes
while (($#)); do
  case $1 in
    --recipe-dir) recipe_dir=${2:?}; shift 2 ;;
    --board) board=${2:?}; shift 2 ;;
    --spotter-lock) spotter_lock=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --no-image) image=no; shift ;;
    -h | --help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
load_recipe "$recipe_dir"
load_board "$board"
lock=$RECIPE_DIR/$RECIPE_LOCK
[[ -f $lock ]] || die "no lock at $lock"
[[ -f $spotter_lock ]] || die "no Spotter lock at '$spotter_lock'"
[[ -n $out ]] || die "--out is required"
mkdir -p "$out/inputs"

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
    die "$what isn't the lock's: its SHA-256 differs from $sum"
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
url=$(json_get "$spotter_lock" debs "$RECIPE_ARCH" url)
sum=$(json_get "$spotter_lock" debs "$RECIPE_ARCH" sha256)
fetch "Spotter's agent ($RECIPE_ARCH)" "$url" "$sum" "$out/inputs/frc-spotter.deb" \
  "Spotter's release must be public, and hold this version (spotter.lock)"
say "fetched what $board's common image is built from, into $out"
