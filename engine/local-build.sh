#!/usr/bin/env bash
# local-build.sh: builds a team's images on a Linux machine, the way the image workflow does, in a
# privileged container (README.md, "Building on your own machine").
#
#   engine/local-build.sh --team DIR [--table FILE] [--settings DIR] [--ssh-keys FILE] \
#       [--packs DIR] [--provision-hook FILE] [--recipe NAME] [--release NAME] [--out DIR] \
#       [--outside-container]
#
#   --team  the team's repository (its table, settings, keys, packs, and hook are read from it,
#           at the workflow's default paths unless given)
#
# Run from Paddock's root, beside Spotter's checkout (../frc-spotter), as root, with: bash, curl,
# xz, sfdisk, losetup, mount, e2fsck, resize2fs, mkfs.ext4, mkfs.fat, yq (mikefarah's, version 4),
# git, and a Java (17 or newer). On a machine that isn't the recipe's architecture (arm64 for
# PhotonVision on Orange Pi), the chroot's programs also need qemu-user-static registered in the
# kernel's binfmt_misc with its "F" flag.
#
# The same steps as the workflow: plan.sh's checks; the tools (PhotonVision's pack, the agent's
# configurations); per board, the inputs fetched and checked, the root grown, the recipe's
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

team="" table=coprocessors.yaml settings=settings keys=authorized_keys packs="" hook=""
recipe="" release="" out="$root/build/local" outside_container=no
while (($#)); do
  case $1 in
    --team) team=$(realpath "${2:?}"); shift 2 ;;
    --table) table=${2:?}; shift 2 ;;
    --settings) settings=${2:?}; shift 2 ;;
    --ssh-keys) keys=${2:?}; shift 2 ;;
    --packs) packs=${2:?}; shift 2 ;;
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
for tool in curl xz sfdisk losetup mount e2fsck resize2fs mkfs.ext4 git java; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
require_yq
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$root/build/local-work
rm -rf "$work"
mkdir -p "$work/tools/packs" "$work/tools/agent-configs" "$work/repository/coprocessors"

# The workflow's plan, as shell variables.
args=(--table "$team/$table" --recipe "$recipe" --release "$release"
  --sha "$(git -C "$team" rev-parse HEAD)")
if [[ -n $hook ]]; then args+=(--hook "$team/$hook"); fi
if [[ -n $packs ]]; then
  for pack in "$team/$packs"/*/; do args+=(--pack "${pack%/}"); done
fi
plan=$(GITHUB_OUTPUT='' "$here/plan.sh" "${args[@]}")
get() {
  sed -n "s/^$1=//p" <<<"$plan"
}
team_number=$(get team) recipe=$(get recipe) version=$(get version) label=$(get version-label)
recipe_hash=$(get recipe-hash) release=$(get release) boards=$(get boards) computers=$(get computers)
load_recipe "$root/recipes/$recipe"

# The tools, as the workflow's first job makes them.
(cd "$root" && ./gradlew -q :photonvision-pack:packFolder :core:workflowTools)
cp -R "$root/packs/photonvision/build/pack/photonvision" "$work/tools/packs/"
if [[ -n $packs ]]; then
  for pack in "$team/$packs"/*/; do
    name=$(basename "$pack")
    cp -R "$pack" "$work/tools/packs/$name"
    java -cp "$root/core/build/tools/*" com.michaelgrundvig.frc.spotter.tools.CoprocessorBuild \
      pack "$pack/pack.yaml" "$work/tools/packs/$name/pack.json"
  done
fi
if [[ -n $hook ]]; then cp "$team/$hook" "$work/tools/hook.sh"; fi
cp "$team/$table" "$work/repository/coprocessors/coprocessors.yaml"
java -cp "$root/core/build/tools/*" com.michaelgrundvig.frc.spotter.tools.CoprocessorBuild \
  agent-configs "$work/repository" "$work/tools/agent-configs"

board_list=""
while IFS= read -r row <&3; do
  board=$(yq -p json -o yaml -r '.board' <<<"$row")
  board_list+="$board "
  load_board "$board"
  inputs="$out/inputs-$board"
  "$here/fetch.sh" --recipe-dir "$RECIPE_DIR" --board "$board" --spotter-lock "$root/spotter.lock" \
    --out "$inputs"
  common="$out/common-$board.img"
  say "$board: the common image"
  xz -dc "$inputs/base.img.xz" >"$common"
  rel_inputs=${inputs#"$root"/}
  [[ $rel_inputs != "$inputs" ]] || die "--out must be inside Paddock's folder, which the chroot sees"
  args=(--board "$board" --inputs "$rel_inputs/inputs" --agent-deb "$rel_inputs/inputs/frc-spotter.deb"
    --out "build/local-work/smoketest-$board")
  for pack in "$work"/tools/packs/*/; do args+=(--pack "build/local-work/tools/packs/$(basename "$pack")"); done
  if [[ -f $work/tools/hook.sh ]]; then args+=(--hook build/local-work/tools/hook.sh); fi
  "$here/chroot-provision.sh" --image "$common" --root-partition "$BOARD_ROOT_PARTITION" \
    --grow-mb "$(yq -p json -o yaml -r '.minimumFreeMb' <<<"$row")" --bind "$root" -- \
    bash "recipes/$recipe/provision.sh" "${args[@]}"
  if [[ -f $work/smoketest-$board/photonvision_config/photon.sqlite ]]; then
    cp "$work/smoketest-$board/photonvision_config/photon.sqlite" "$out/empty-photon-$board.sqlite"
  fi
done 3< <(yq -p json -o=json -I=0 '.[]' <<<"$boards")

mkdir -p "$out/release"
cp "$root/packs/photonvision/build/pack/photonvision/lib/photonvision-helper.jar" "$work/tools/"
while IFS= read -r row <&3; do
  name=$(yq -p json -o yaml -r '.name' <<<"$row")
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
    --computer "$name" --table "$team/$table" --release "$release" --recipe-hash "$recipe_hash" \
    --agent-config "$work/tools/agent-configs/$name.json" --label "$label=$version" \
    --label "board=$board" --keys "$team/$keys" --settings "$team/$settings" \
    --inputs "$stamp_inputs" --stamp-out "$out/release/$(basename "$image" .img).stamp.json"
  xz -T0 -c "$image" >"$out/release/${image##*/}.xz"
  rm -f "$image"
done 3< <(yq -p json -o=json -I=0 '.[]' <<<"$computers")
"$RECIPE_DIR/notice.sh" --boards "$board_list" --spotter-lock "$root/spotter.lock" \
  >"$out/release/NOTICE.md"
"$here/manifest.sh" "$out/release"
say "the release's files are in $out/release"
