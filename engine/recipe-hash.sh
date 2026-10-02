#!/usr/bin/env bash
# recipe-hash.sh: the hash of everything a recipe's common image is made from, in lowercase hex:
# Paddock's engine, the recipe's folder, what the team's images get (its packages, by URL and
# sha256, and its files, with their destinations and modes), and the team's provision hook.
# Documentation and tests are left out: a change to them makes no other image. So a common image is
# rebuilt (and its cache missed) only when something that makes it has changed.
#
#   recipe-hash.sh --recipe-dir DIR --software DIR [--hook FILE]
#
#   --software  what the images get, as plan.sh writes it: packages.list and files/
#
# It hashes the files themselves, by their paths from Paddock's root (the team's, by their place
# among what it gives), with their content and whether they're executable.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
root=$(cd "$here/.." && pwd)

recipe_dir="" software="" hook=""
while (($#)); do
  case $1 in
    --recipe-dir) recipe_dir=${2:?}; shift 2 ;;
    --software) software=${2:?}; shift 2 ;;
    --hook) hook=${2:?}; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
load_recipe "$recipe_dir"
[[ -f $software/packages.list && -f $software/files/files.list ]] ||
  die "--software must be what plan.sh writes: packages.list and files/"
[[ -z $hook || -f $hook ]] || die "no hook at $hook"

# One line per file: its name, whether it's executable, and its sha256. Paths that aren't there
# are left out; so are tests and documentation, unless asked for all.
listing() {
  local base=$1 prefix=$2 all=$3 path paths=()
  shift 3
  for path; do
    if [[ -e $base/$path ]]; then
      paths+=("$path")
    fi
  done
  ((${#paths[@]})) || return 0
  (
    cd "$base"
    if [[ $all == all ]]; then
      find "${paths[@]}" -type f -print0
    else
      find "${paths[@]}" -type f ! -path '*/test/*' ! -path '*/build/*' ! -name '*.md' -print0
    fi | LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        printf '%s%s %s %s\n' "$prefix" "$file" "$([[ -x $file ]] && echo x || echo -)" \
          "$(sha256sum <"$file" | cut -c1-64)"
      done
  )
}

{
  listing "$root" "" some engine "recipes/$(basename "$RECIPE_DIR")"
  listing "$software" "team-software/" all packages.list files
  if [[ -n $hook ]]; then
    printf 'team-hook %s\n' "$(sha256sum <"$hook" | cut -c1-64)"
  fi
} | sha256sum | cut -c1-64
