#!/usr/bin/env bash
# inspect-root.sh: checks a built image's root, as its computers will boot it, before it's
# released. inspect-image.sh runs it on the image it mounts; the tests run it on folders.
#
#   inspect-root.sh --plan DIR --image NAME --root DIR
#
# Two things, from what the build already knows:
#   - every file a step put in place (file: and download:, the plan's steps.list) is there at its
#     to:, with the mode the step gave it (the last step's, when two put a file at one path);
#   - the init adapter's checks (for systemd: every unit file and drop-in in /etc/systemd/system
#     through systemd-analyze verify, every masked unit one the image has, and /etc/fstab through
#     systemd's generator).
# Names every problem at once. Needs no root.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" root=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --root) need_value "$@"; root=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $plan && -n $image ]] || die "--plan and --image are required"
[[ -n $root && -d $root ]] || die "--root must be an existing folder: the image's root"
load_image "$plan" "$image"
root=$(cd "$root" && pwd)
root=${root%/}

problems=$(init_inspect_tools)
if [[ -n $problems ]]; then
  die "can't inspect $image:"$'\n'"  - ${problems//$'\n'/$'\n'  - }"
fi

# Why a path in the image can't be checked from outside it; nothing if it can. An absolute link on
# the way would resolve on this machine.
unreachable() {
  local part=$root name names
  IFS=/ read -ra names <<<"${1#/}"
  for name in "${names[@]:0:${#names[@]}-1}"; do
    part=$part/$name
    if [[ -L $part && $(readlink "$part") == /* ]]; then
      echo "goes through ${part#"$root"}, a link to $(readlink "$part")"
      return
    fi
  done
}

# A file a step put at TO with MODE: still there, still that mode.
check_file() {
  local what=$1 to=$2 mode=$3 why have
  why=$(unreachable "$to")
  if [[ -n $why ]]; then
    echo "$to ($what) can't be checked: it $why"
    return
  fi
  if [[ ! -f $root$to || -L $root$to ]]; then
    echo "$to isn't in the image, though $what put it there"
    return
  fi
  have=$(file_mode "$(stat -c %a "$root$to")")
  [[ $have == "$mode" ]] || echo "$to has mode $have, but $what gave it $mode"
  return 0
}

# What each step put where, the last step's for a path two steps wrote.
declare -A step_of=() mode_of=()
targets=()
n=0
while IFS=$'\t' read -r kind a b c d <&3; do
  n=$((n + 1))
  case $kind in
    file) what="step $n (file: $a)" to=$b mode=$c ;;
    download) what="step $n (download: ${b##*/})" to=$c mode=$d ;;
    *) continue ;;
  esac
  [[ -n ${step_of[$to]:-} ]] || targets+=("$to")
  step_of[$to]=$what
  mode_of[$to]=$mode
done 3<"$IMAGE_DIR/steps.list"

problems=$(
  for to in "${targets[@]}"; do
    check_file "${step_of[$to]}" "$to" "${mode_of[$to]}"
  done
  init_inspect "$root"
)
if [[ -n $problems ]]; then
  count=$(grep -c . <<<"$problems")
  die "$image's built root has $count problem$( ((count == 1)) || echo s):"$'\n'"  - ${problems//$'\n'/$'\n'  - }"
fi
say "inspected $image: the ${#targets[@]} file(s) its steps put in place are there, and its configuration passes its init's checks"
