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

mnt="" loop=""
# Unmounts the chroot and detaches the image. Fails, saying what's left, if it can't: the next
# step would otherwise work on an image that's still mounted.
cleanup() {
  local status=0
  if [[ -n $mnt ]]; then
    if [[ -e $mnt/etc/resolv.conf.coproc-saved ]]; then
      mv -f "$mnt/etc/resolv.conf.coproc-saved" "$mnt/etc/resolv.conf" || status=1
    fi
    if mountpoint -q "$mnt"; then
      umount --recursive "$mnt" || { say "couldn't unmount $mnt"; status=1; }
    fi
    if ((status == 0)); then
      rmdir "$mnt" || status=1
    fi
  fi
  if [[ -n $loop ]] && ((status == 0)); then
    losetup --detach "$loop" || { say "couldn't detach $loop"; status=1; }
  fi
  if ((status == 0)); then
    mnt="" loop=""
  fi
  return "$status"
}
on_exit() {
  cleanup || say "left mounted: ${mnt:-nothing}; attached: ${loop:-nothing}. Unmount by hand before rerunning"
}
trap on_exit EXIT

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
  # The root grown by the headroom the recipe's board file gives it.
  truncate -s "+$(yq -p json -o yaml -r '.minimumFreeMb' <<<"$row")M" "$common"
  if [[ $(sfdisk --dump "$common" | sed -n 's/^label: *//p') == gpt ]]; then
    sfdisk --quiet --relocate gpt-bak-std "$common"
  fi
  echo ', +' | sfdisk --quiet --no-reread --no-tell-kernel -N "$BOARD_ROOT_PARTITION" "$common"
  loop=$(losetup --find --show --partscan "$common")
  root_dev="${loop}p$BOARD_ROOT_PARTITION"
  e2fsck -pf "$root_dev"
  resize2fs "$root_dev"
  # A chroot of the image's root, as photon-image-runner makes one: Paddock at /tmp/build.
  mnt=$(mktemp -d)
  mount "$root_dev" "$mnt"
  mount -t proc proc "$mnt/proc"
  mount -t sysfs sys "$mnt/sys"
  mount --rbind /dev "$mnt/dev"
  # So unmounting the chroot's /dev never reaches the machine's own.
  mount --make-rslave "$mnt/dev"
  mount -t tmpfs tmpfs "$mnt/run"
  mkdir -p "$mnt/tmp/build"
  mount --bind "$root" "$mnt/tmp/build"
  mv -f "$mnt/etc/resolv.conf" "$mnt/etc/resolv.conf.coproc-saved"
  cp /etc/resolv.conf "$mnt/etc/resolv.conf"
  rel_inputs=${inputs#"$root"/}
  [[ $rel_inputs != "$inputs" ]] || die "--out must be inside Paddock's folder, which the chroot sees"
  pack_args=""
  for pack in "$work"/tools/packs/*/; do pack_args+=" --pack build/local-work/tools/packs/$(basename "$pack")"; done
  hook_args=""
  if [[ -f $work/tools/hook.sh ]]; then hook_args="--hook build/local-work/tools/hook.sh"; fi
  # shellcheck disable=SC2086 # the packs and the hook are words, by design
  chroot "$mnt" bash -c "cd /tmp/build && bash recipes/$recipe/provision.sh --board $board \
    --inputs $rel_inputs/inputs --agent-deb $rel_inputs/inputs/frc-coprocessor-agent.deb \
    $pack_args $hook_args --out build/local-work/smoketest-$board"
  if [[ -f $work/smoketest-$board/photonvision_config/photon.sqlite ]]; then
    cp "$work/smoketest-$board/photonvision_config/photon.sqlite" "$out/empty-photon-$board.sqlite"
  fi
  # Zeros where nothing is, so the image compresses as CI's does.
  cat /dev/zero >"$mnt/coproc-zeros" 2>/dev/null || true
  rm -f "$mnt/coproc-zeros"
  cleanup || die "couldn't unmount $board's common image: stopping"
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
