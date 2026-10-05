#!/usr/bin/env bash
# local-build.sh: builds a team's images as the workflow does, without publishing, as root in a
# privileged container with this machine's /dev (docs/how-to.md, "Build on your own Linux
# machine").
#
#   local-build.sh --team DIR [--config FILE] [--notice FILE] [--release NAME] [--out DIR] \
#       [--outside-container]
#
#   --config   from the team's repository (default paddock.yaml)
#   --notice   beside paddock.yaml (default NOTICE.md, if there)
#   --release  default build-<commit>
#   --out      default build/local; the release's files go in OUT/release
#
# What the build runs (the base's programs, packages' scripts, the team's) runs as root with this
# machine's devices: the container is for the mounts, not isolation. Another architecture needs
# qemu-user-static registered with binfmt_misc's "F" flag. Needs curl, xz, gzip, sfdisk, losetup,
# blkid, mount, chroot, fstrim, e2fsprogs, git, and mikefarah's yq v4.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

team="" config=paddock.yaml notice=NOTICE.md release="" out="$root/build/local" outside_container=no
while (($#)); do
  case $1 in
    --team) need_value "$@"; team=$(realpath "$2"); shift 2 ;;
    --config) need_value "$@"; config=$2; shift 2 ;;
    --notice) need_value "$@"; notice=$2; shift 2 ;;
    --release) need_value "$@"; release=$2; shift 2 ;;
    --out) need_value "$@"; out=$2; shift 2 ;;
    --outside-container) outside_container=yes; shift ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $team && -d $team ]] || die "--team is required: the team's repository"
((EUID == 0)) || die "needs root (in a privileged container): it mounts images"
if [[ $outside_container == no && ! -e /run/.containerenv && ! -e /.dockerenv ]]; then
  die "not in a container (Docker or Podman): run it in one, or pass --outside-container"
fi
for tool in curl xz gzip sfdisk losetup blkid mount chroot fstrim git; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
require_yq
# A repository mounted into the container is someone else's to its root: Git would refuse it.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=$team
mkdir -p "$out"
out=$(cd "$out" && pwd)
plan=$out/plan

# A stop (docker stop, Ctrl-C) reaches the running step, whose own cleanup then unmounts and detaches.
child=""
trap '[[ -n $child ]] && kill -TERM "$child" 2>/dev/null; wait; exit 130' TERM INT
run() {
  "$@" &
  child=$!
  wait "$child"
  child=""
}

run "$here/plan.sh" --config "$team/$config" --repo "$team" --out "$plan" ${release:+--release "$release"} >/dev/null
load_plan "$plan"
config_dir=$(cd "$team/$(dirname "$config")" && pwd)

for dir in "$plan"/images/*/; do
  image=$(basename "$dir")
  run "$here/fetch.sh" --plan "$plan" --image "$image" --out "$out/inputs-$image"
  run "$here/build-image.sh" --plan "$plan" --image "$image" --config-dir "$config_dir" \
    --inputs "$out/inputs-$image" --out "$out/$image.img"
done

rm -rf "$out/release"
mkdir -p "$out/release"
for env in "$plan"/computers/*.env; do
  computer=$(basename "$env" .env)
  load_computer "$plan" "$computer"
  name=$computer-$RELEASE
  say "$computer: stamping"
  cp --sparse=always "$out/$COMPUTER_IMAGE.img" "$out/$name.img"
  run "$here/stamp-image.sh" --plan "$plan" --computer "$computer" "$out/$name.img" \
    --stamp-out "$out/release/$name.stamp.json"
  xz -T0 -c "$out/$name.img" >"$out/release/$name.img.xz"
  rm -f "$out/$name.img"
done
notice_args=()
if [[ -f $config_dir/$notice && ! -L $config_dir/$notice ]]; then
  cp "$config_dir/$notice" "$out/release/"
  notice_args=(--notice "$(basename "$notice")")
fi
run "$here/manifest.sh" "$out/release" "${notice_args[@]}"
say "the release's files are in $out/release"
