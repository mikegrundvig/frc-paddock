#!/usr/bin/env bash
# plan.sh: checks a build's inputs and says what to build. The image workflow's first job runs it;
# nothing is downloaded or built until it passes.
#
#   plan.sh --table FILE [--recipe NAME] [--spotter-lock FILE] [--vendordep FILE] \
#       [--pack DIR]... [--hook FILE] [--release NAME] [--sha COMMIT]
#
#   --recipe     the recipe (a folder in recipes/); else the table's image.recipe; else
#                photonvision-orangepi
#   --vendordep  the robot code's PhotonLib vendordep, whose version the lock's must equal (for a
#                recipe whose lock pins the software the robot code is built against)
#
# It checks:
#   - the table: the team number, and each computer's name, address, and board (image.board, one
#     of the recipe's);
#   - the recipe's lock: its version (the vendordep's, if given), each input's https URL and real
#     sha256, and each board's base image in use (the one the board's file names); Spotter's lock,
#     its .deb for the recipe's architecture;
#   - the release name: a published one is coprocessors-<something>.
# Then it prints, as name=value lines (appended to $GITHUB_OUTPUT in Actions): team, recipe,
# runner (the recipe's runner), version, version-label, recipe-hash, release, publish (whether
# --release was given: without one, the images are built under a name made from the commit, and
# not released), boards (a JSON list: board, url, sha256, minimumFreeMb), and
# computers (a JSON list: name, board).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

table="" recipe="" spotter_lock="$here/../spotter.lock" vendordep="" release="" sha=""
extra=()
while (($#)); do
  case $1 in
    --table) table=${2:?}; shift 2 ;;
    --recipe) recipe=${2-}; shift 2 ;;
    --spotter-lock) spotter_lock=${2:?}; shift 2 ;;
    --vendordep) vendordep=${2-}; shift 2 ;;
    --pack | --hook) extra+=("$1" "${2:?}"); shift 2 ;;
    --release) release=${2-}; shift 2 ;;
    --sha) sha=${2:?}; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
require_yq
[[ -f $table ]] || die "no table at '$table'"
if [[ -z $recipe ]]; then
  recipe=$(table_recipe "$table")
fi
recipe=${recipe:-$DEFAULT_RECIPE}
is_name "$recipe" || die "recipe '$recipe' isn't a recipe's name"
[[ -d $here/../recipes/$recipe ]] || die "no recipe named '$recipe' (recipes/$recipe)"
load_recipe "$here/../recipes/$recipe"
lock=$RECIPE_DIR/$RECIPE_LOCK

check_table "$table"
team=$(table_get '.team' "$table")

# A URL and sha256 from a lock, checked. $1 names it for messages.
checked_pair() {
  local what=$1 url=$2 sum=$3
  [[ $url == https://* ]] || die "$what's URL is missing or not https ('$url')"
  [[ $url =~ ^[A-Za-z0-9:/._~%+-]+$ ]] || die "$what's URL has unexpected characters"
  is_sha256 "$sum" || die "$what's sha256 is missing or a placeholder ('$sum')"
}

version=$(lock_get '.version' "$lock")
[[ -n $version ]] || die "$RECIPE_LOCK gives no version"
[[ $version =~ ^[A-Za-z0-9._+-]+$ ]] || die "$RECIPE_LOCK's version '$version' has unexpected characters"
if [[ -n $vendordep ]]; then
  [[ -f $vendordep ]] || die "no vendordep at $vendordep"
  robot_version=$(yq -p json -o yaml -r '.version // ""' "$vendordep")
  [[ $version == "$robot_version" ]] ||
    die "$RECIPE_LOCK is for $version, but the robot code uses $robot_version ($vendordep): pick the recipe version that matches"
fi
for input in $RECIPE_INPUTS; do
  checked_pair "$RECIPE_LOCK: ${input%%=*}" "$(lock_get "${input#*=}.url" "$lock")" \
    "$(lock_get "${input#*=}.sha256" "$lock")"
done
[[ -f $spotter_lock ]] || die "no Spotter lock at $spotter_lock"
checked_pair "spotter.lock: the agent for $RECIPE_ARCH" \
  "$(ARCH=$RECIPE_ARCH lock_get '.debs[strenv(ARCH)].url' "$spotter_lock")" \
  "$(ARCH=$RECIPE_ARCH lock_get '.debs[strenv(ARCH)].sha256' "$spotter_lock")"

boards=()
for board in $(yq -r '[.computers[].image.board] | unique | .[]' "$table"); do
  load_board "$board"
  url=$(BOARD=$board lock_get '.images[strenv(BOARD)].url' "$lock")
  sum=$(BOARD=$board lock_get '.images[strenv(BOARD)].sha256' "$lock")
  checked_pair "$RECIPE_LOCK: $board's base image" "$url" "$sum"
  [[ ${url##*/} == "$BOARD_BASE_ASSET" ]] ||
    die "$RECIPE_LOCK: $board's base image is ${url##*/}, but $BOARD_TITLE's is $BOARD_BASE_ASSET"
  boards+=("$(
    BOARD=$board URL=$url SUM=$sum FREE=$BOARD_MINIMUM_FREE_MB \
      yq -n -o=json -I=0 '{"board": strenv(BOARD), "url": strenv(URL), "sha256": strenv(SUM),
        "minimumFreeMb": env(FREE)}'
  )")
done
boards_json="[$(IFS=,; echo "${boards[*]}")]"
computers_json=$(yq -o=json -I=0 '[.computers[] | {"name": .name, "board": .image.board}]' "$table")

if [[ -n $release ]]; then
  publish=true
  # A published release has the name a tag would trigger the workflow with.
  [[ $release == coprocessors-* ]] || die "release name '$release': a release is named coprocessors-<something>"
else
  publish=false
  [[ $sha =~ ^[0-9a-f]{7,40}$ ]] || die "without --release, --sha COMMIT names the build"
  release="build-${sha:0:12}"
fi
[[ $release =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
  die "release name '$release': up to 64 letters, digits, '.', '_', '-', starting with a letter or digit"

recipe_hash=$("$here/recipe-hash.sh" --recipe-dir "$RECIPE_DIR" "${extra[@]}")

out=${GITHUB_OUTPUT:-/dev/stdout}
{
  echo "team=$team"
  echo "recipe=$recipe"
  echo "runner=$RECIPE_RUNNER"
  echo "version=$version"
  echo "version-label=$RECIPE_VERSION_LABEL"
  echo "recipe-hash=$recipe_hash"
  echo "release=$release"
  echo "publish=$publish"
  echo "boards=$boards_json"
  echo "computers=$computers_json"
} >>"$out"
