#!/usr/bin/env bash
# recipe-hash.sh: the hash of everything a recipe's common image is made from, in lowercase hex:
# Paddock's engine, the recipe's folder, the packs Paddock builds (PhotonVision's, with Paddock's
# core, which its helper is built from), Spotter's lock, and the team's own packs and provision
# hook. Documentation and tests are left out: a change to them makes no other image. So a common
# image is rebuilt (and its cache missed) only when something that makes it has changed.
#
#   recipe-hash.sh --recipe-dir DIR [--pack DIR]... [--hook FILE]
#
# It hashes the files themselves, by their paths from Paddock's root (a team's, by their place
# among the team's packs and hook), with their content and whether they're executable.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
root=$(cd "$here/.." && pwd)

recipe_dir="" extra=()
while (($#)); do
  case $1 in
    --recipe-dir) recipe_dir=${2:?}; shift 2 ;;
    --pack | --hook) extra+=("$1" "${2:?}"); shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
load_recipe "$recipe_dir"

# One line per file: its name, whether it's executable, and its sha256. Paths that aren't there
# are left out.
listing() {
  local base=$1 prefix=$2 path paths=()
  shift 2
  for path; do
    if [[ -e $base/$path ]]; then
      paths+=("$path")
    fi
  done
  ((${#paths[@]})) || return 0
  (
    cd "$base"
    find "${paths[@]}" -type f ! -path '*/test/*' ! -path '*/build/*' ! -name '*.md' -print0 |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        printf '%s%s %s %s\n' "$prefix" "$file" "$([[ -x $file ]] && echo x || echo -)" \
          "$(sha256sum <"$file" | cut -c1-64)"
      done
  )
}

{
  listing "$root" "" engine "recipes/$(basename "$RECIPE_DIR")" packs core spotter.lock gradle/quality.gradle
  i=0
  while ((i < ${#extra[@]})); do
    kind=${extra[$i]#--} path=${extra[$((i + 1))]}
    if [[ -d $path ]]; then
      listing "$path" "team-$kind/$(basename "$path")/" .
    else
      [[ -f $path ]] || die "no $kind at $path"
      printf 'team-%s %s\n' "$kind" "$(sha256sum <"$path" | cut -c1-64)"
    fi
    i=$((i + 2))
  done
} | sha256sum | cut -c1-64
