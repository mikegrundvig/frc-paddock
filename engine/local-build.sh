#!/usr/bin/env bash
# local-build.sh: builds a team's images on a Linux machine, the way the image workflow does, in a
# privileged container (README.md, "Building on your own machine").
#
#   engine/local-build.sh --team DIR [--config FILE] [--settings DIR] [--ssh-keys FILE] \
#       [--provision-hook FILE] [--recipe NAME] [--release NAME] [--out DIR] [--outside-container]
#
#   --team  the team's repository (its input, settings, keys, and hook are read from it, at the
#           workflow's default paths unless given)
#
# Run from Paddock's root, as root, with: bash, curl, xz, sfdisk, losetup, mount, e2fsck,
# resize2fs, mkfs.ext4, mkfs.fat, yq (mikefarah's, version 4), git, python3, and a Java (17 or
# newer). On a machine that isn't the recipe's architecture (arm64 for PhotonVision on Orange Pi),
# the chroot's programs also need qemu-user-static registered in the kernel's binfmt_misc with its
# "F" flag.
#
# The same steps as the workflow: plan.sh's checks, and what the images get; the settings tool;
# per board, the inputs and the team's packages fetched and checked, the root grown, the recipe's
# provision.sh run in a chroot of it; per computer, layout.sh and stamp-image.sh; then the notice
# and manifest.sh. Downloads are kept in OUT/inputs-BOARD.
#
# It mounts images and bind-mounts the machine's /dev into a chroot, so it refuses to run outside
# a container unless told --outside-container.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

team="" config=paddock.yaml settings=settings keys=authorized_keys hook=""
recipe="" release="" out="$root/build/local" outside_container=no
while (($#)); do
  case $1 in
    --team) team=$(realpath "${2:?}"); shift 2 ;;
    --config) config=${2:?}; shift 2 ;;
    --settings) settings=${2:?}; shift 2 ;;
    --ssh-keys) keys=${2:?}; shift 2 ;;
    --provision-hook) hook=${2:?}; shift 2 ;;
    --recipe) recipe=${2:?}; shift 2 ;;
    --release) release=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --outside-container) outside_container=yes; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $team && -d $team ]] || die "--team is required: the team's repository"
((EUID == 0)) || die "needs root (in a privileged container): it mounts images"
if [[ $outside_container == no && ! -e /run/.containerenv && ! -e /.dockerenv ]]; then
  die "not in a container (Docker or Podman): run it in one, or pass --outside-container"
fi
for tool in curl xz sfdisk losetup mount e2fsck resize2fs mkfs.ext4 git java python3; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
require_yq
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$root/build/local-work
rm -rf "$work"
mkdir -p "$work/tools"

# The workflow's plan, as shell variables, and what the images get.
args=(--config "$team/$config" --repo "$team" --recipe "$recipe" --release "$release"
  --software "$work/tools/software" --sha "$(git -C "$team" rev-parse HEAD)")
if [[ -n $hook ]]; then args+=(--hook "$team/$hook"); fi
plan=$(GITHUB_OUTPUT='' "$here/plan.sh" "${args[@]}")
get() {
  sed -n "s/^$1=//p" <<<"$plan"
}
team_number=$(get team) recipe=$(get recipe) version=$(get version) label=$(get version-label)
recipe_hash=$(get recipe-hash) release=$(get release) boards=$(get boards) computers=$(get computers)
load_recipe "$root/recipes/$recipe"

# The tools, as the workflow's first job makes them.
(cd "$root" && ./gradlew -q :photonvision-pack:jar)
cp "$root/packs/photonvision/build/libs/photonvision-helper.jar" "$work/tools/"
if [[ -n $hook ]]; then cp "$team/$hook" "$work/tools/hook.sh"; fi

board_list=""
while IFS= read -r row <&3; do
  board=$(yq -p json -o yaml -r '.board' <<<"$row")
  board_list+="$board "
  load_board "$board"
  inputs="$out/inputs-$board"
  "$here/fetch.sh" --recipe-dir "$RECIPE_DIR" --board "$board" \
    --packages "$work/tools/software/packages.list" --out "$inputs"
  common="$out/common-$board.img"
  say "$board: the common image"
  xz -dc "$inputs/base.img.xz" >"$common"
  rel_inputs=${inputs#"$root"/}
  [[ $rel_inputs != "$inputs" ]] || die "--out must be inside Paddock's folder, which the chroot sees"
  args=(--board "$board" --inputs "$rel_inputs/inputs" --packages "$rel_inputs/packages"
    --files build/local-work/tools/software/files --out "build/local-work/smoketest-$board")
  if [[ -f $work/tools/hook.sh ]]; then args+=(--hook build/local-work/tools/hook.sh); fi
  "$here/chroot-provision.sh" --image "$common" --root-partition "$BOARD_ROOT_PARTITION" \
    --grow-mb "$(yq -p json -o yaml -r '.minimumFreeMb' <<<"$row")" --bind "$root" -- \
    bash "recipes/$recipe/provision.sh" "${args[@]}"
  if [[ -f $work/smoketest-$board/photonvision_config/photon.sqlite ]]; then
    cp "$work/smoketest-$board/photonvision_config/photon.sqlite" "$out/empty-photon-$board.sqlite"
  fi
done 3< <(yq -p json -o=json -I=0 '.[]' <<<"$boards")

mkdir -p "$out/release"
while IFS= read -r row <&3; do
  name=$(yq -p json -o yaml -r '.hostname' <<<"$row")
  board=$(yq -p json -o yaml -r '.board' <<<"$row")
  image="$out/$team_number-$name-$release.img"
  say "$name: stamping"
  stamp_inputs="$work/stamp-inputs-$board"
  mkdir -p "$stamp_inputs"
  if [[ -f $out/empty-photon-$board.sqlite ]]; then
    cp "$out/empty-photon-$board.sqlite" "$stamp_inputs/empty-photon.sqlite"
  fi
  printf '#!/bin/sh\nexec java -jar %s settings-db "$@"\n' "$work/tools/photonvision-helper.jar" \
    >"$stamp_inputs/settings-tool"
  chmod +x "$stamp_inputs/settings-tool"
  cp --sparse=always "$out/common-$board.img" "$image"
  "$here/layout.sh" --recipe-dir "$RECIPE_DIR" --board "$board" "$image"
  "$here/stamp-image.sh" --recipe-dir "$RECIPE_DIR" --board "$board" "$image" -- \
    --computer "$name" --config "$team/$config" --release "$release" --recipe-hash "$recipe_hash" \
    --label "$label=$version" --label "board=$board" --keys "$team/$keys" \
    --settings "$team/$settings" --inputs "$stamp_inputs" \
    --stamp-out "$out/release/$(basename "$image" .img).stamp.json"
  xz -T0 -c "$image" >"$out/release/${image##*/}.xz"
  rm -f "$image"
done 3< <(yq -p json -o=json -I=0 '.[]' <<<"$computers")
"$RECIPE_DIR/notice.sh" --boards "$board_list" --packages "$work/tools/software/packages.list" \
  >"$out/release/NOTICE.md"
"$here/manifest.sh" "$out/release"
say "the release's files are in $out/release"
