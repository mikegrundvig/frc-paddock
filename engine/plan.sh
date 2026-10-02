#!/usr/bin/env bash
# plan.sh: checks a build's inputs and says what to build. The image workflow's first job runs it;
# nothing is downloaded or built until it passes.
#
#   plan.sh --config FILE --repo DIR [--recipe NAME] [--vendordep FILE] [--hook FILE] \
#       [--software DIR] [--release NAME] [--sha COMMIT]
#
#   --config     Paddock's input (paddock.yaml): the team, its computers, and the packages and
#                files the images get (lib/common.sh, check_config)
#   --repo       the team's repository, where the files' paths are
#   --recipe     the recipe (a folder in recipes/); else photonvision-orangepi
#   --vendordep  the robot code's PhotonLib vendordep, whose version the lock's must equal (for a
#                recipe whose lock pins the software the robot code is built against)
#   --software   where to write what the images get, for the jobs after this one: packages.list
#                (each package's sha256 and url, a line each, in the input's order) and files/
#                (each file, by its number, and files.list: its mode, destination, and number, a
#                line each)
#
# It checks:
#   - Paddock's input, whole: every problem in it is listed at once;
#   - the recipe's lock: its version (the vendordep's, if given), each input's https URL and real
#     sha256, and each board's base image in use (the one the board's file names);
#   - the release name: a published one is coprocessors-<something>.
# Then it prints, as name=value lines (appended to $GITHUB_OUTPUT in Actions): team, recipe,
# runner (the recipe's runner), version, version-label, recipe-hash, release, publish (whether
# --release was given: without one, the images are built under a name made from the commit, and
# not released), boards (a JSON list: board, url, sha256, minimumFreeMb), and computers (a JSON
# list: hostname, board).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

config="" repo="" recipe="" vendordep="" hook="" software="" release="" sha=""
while (($#)); do
  case $1 in
    --config) config=${2:?}; shift 2 ;;
    --repo) repo=${2:?}; shift 2 ;;
    --recipe) recipe=${2-}; shift 2 ;;
    --vendordep) vendordep=${2-}; shift 2 ;;
    --hook) hook=${2-}; shift 2 ;;
    --software) software=${2:?}; shift 2 ;;
    --release) release=${2-}; shift 2 ;;
    --sha) sha=${2:?}; shift 2 ;;
    -h | --help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
require_yq
[[ -n $config ]] || die "--config is required: Paddock's input, paddock.yaml"
[[ -n $repo && -d $repo ]] || die "--repo is required: the team's repository"
recipe=${recipe:-$DEFAULT_RECIPE}
is_name "$recipe" || die "recipe '$recipe' isn't a recipe's name"
[[ -d $here/../recipes/$recipe ]] || die "no recipe named '$recipe' (recipes/$recipe)"
load_recipe "$here/../recipes/$recipe"
lock=$RECIPE_DIR/$RECIPE_LOCK
[[ -z $hook || -f $hook ]] || die "no provision hook at $hook"

check_config "$config" "$repo"
team=$(config_get '.team' "$config")

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

boards=()
for board in $(yq -r '[.computers[].board] | unique | .[]' "$config"); do
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
computers_json=$(yq -o=json -I=0 '[.computers[] | {"hostname": .hostname, "board": .board}]' "$config")

if [[ -n $release ]]; then
  publish=true
  # A published release has the name a tag would trigger the workflow with.
  [[ $release == coprocessors-* ]] || die "release name '$release': a release is named coprocessors-<something>"
else
  publish=false
  [[ $sha =~ ^[0-9a-f]{7,40}$ ]] || die "without --release, --sha COMMIT names the build"
  release="build-${sha:0:12}"
fi
# The release is each image's IMAGE_VERSION in /etc/os-release, whose characters these are.
[[ $release =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
  die "release name '$release': up to 64 lowercase letters, digits, '.', '_', '-', starting with a letter or digit"

# What the images get, as the later jobs read it without yq: the packages, and the files with
# their modes and destinations.
if [[ -z $software ]]; then
  software=$(mktemp -d)
  trap 'rm -rf "$software"' EXIT
fi
rm -rf "$software/files" "$software/packages.list"
mkdir -p "$software/files"
yq -r '(.packages // [])[] | .sha256 + " " + .url' "$config" >"$software/packages.list"
n=$(yq -r '(.files // []) | length' "$config")
for ((i = 0; i < n; i++)); do
  cp "$repo/$(config_get ".files[$i].path" "$config")" "$software/files/$i"
  printf '%s %s %s\n' "$(file_mode "$(config_get ".files[$i].mode" "$config")")" \
    "$(config_get ".files[$i].destination" "$config")" "$i"
done >"$software/files/files.list"

recipe_hash=$("$here/recipe-hash.sh" --recipe-dir "$RECIPE_DIR" --software "$software" ${hook:+--hook "$hook"})

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
